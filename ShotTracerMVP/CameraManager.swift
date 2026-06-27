import AVFoundation
import Vision
import CoreGraphics
import UIKit
import Photos

fileprivate enum ArrowDirection {
    case left
    case right
    case bottom
    case bottomRight
}

final class CameraManager: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue  = DispatchQueue(label: "camera.vision.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioConnection: AVCaptureConnection?
    private var impactSoundTime: CFTimeInterval?
    
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDevice: AVCaptureDevice?

    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackingObservation: VNDetectedObjectObservation?
    private var phase: InternalPhase = .idle
    private enum InternalPhase { case idle, searching, armed, shotTracking }

    private var baselinePoint: CGPoint?
    private var shotStartTime: CFTimeInterval?
    private var shotEndTime: CFTimeInterval?
    private var recordingStartTime: CFTimeInterval?

    private var trackingFrameCounter: Int = 0
    private let maxTrackingFrames: Int = 90
    private var activeTrackingFrames: Int = 0

    private var initialBoxArea: CGFloat = 0.0
    private var initialBoxWidth: CGFloat = 0.0

    private struct CompositeData {
        let points: [CGPoint]
        let delay: Double
        let duration: Double
        let carry: Double
        let speed: Double
        let launch: Double
        let apex: Double
    }
    private var lastCompositeData: CompositeData?
    private var currentZoomScale: CGFloat = 1.0

    private let moveThreshold: CGFloat = 0.006
    private var overThresholdCount: Int = 0
    private let requiredConsecutive: Int = 2

    private let stopMoveThreshold: CGFloat = 0.003
    private var stopStabilityCounter: Int = 0
    private let requiredStopFrames: Int = 25

    private let minConfidence: VNConfidence = 0.30
    
    private var stabilityCounter: Int = 0
    private let requiredStabilityFrames = 45
    private var autoScanVisionBox: CGRect?

    var pointsToDraw: [CGPoint] = []

    var onTrackedPoint: ((CGPoint) -> Void)?
    var onShotBegan: (() -> Void)?
    var onShotEnded: (() -> Void)?
    var onTrackingLost: (() -> Void)?
    var onDebugBoundingBox: ((CGRect?) -> Void)?
    var onAutoLockComplete: (() -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?
    var onVideoSaved: (() -> Void)?

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = layer
    }

    func start() {
        configureIfNeeded()
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == false { self?.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == true { self?.session.stopRunning() }
        }
    }

    func setZoom(scale: CGFloat) {
        guard let device = videoDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let zoomFactor = max(1.0, min(scale, device.activeFormat.videoMaxZoomFactor))
                device.videoZoomFactor = zoomFactor
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomScale = zoomFactor }
            } catch {
                print("DEBUG: ズーム設定エラー")
            }
        }
    }

    private func startRecording() {
        guard !movieOutput.isRecording else { return }
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = self.getCurrentVideoOrientation()
            }
        }
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
        movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        DispatchQueue.main.async { self.onRecordingStateChanged?(true) }
    }

    func stopRecordingWithMetrics(carry: Double, speed: Double, launch: Double, apex: Double) {
        guard phase != .idle else { return }
        self.shotEndTime = CACurrentMediaTime()
        self.phase = .idle
        
        let rStart = self.recordingStartTime ?? CACurrentMediaTime()
        let sStart = self.shotStartTime ?? CACurrentMediaTime()
        let sEnd = self.shotEndTime ?? CACurrentMediaTime()
        let delay = max(0, sStart - rStart)
        let duration = max(0.1, sEnd - sStart)
        
        self.lastCompositeData = CompositeData(
            points: self.pointsToDraw,
            delay: delay,
            duration: duration,
            carry: carry,
            speed: speed,
            launch: launch,
            apex: apex
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
            DispatchQueue.main.async { self.onRecordingStateChanged?(false) }
        }
    }

    private func getCurrentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    func processExternalBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, time: CMTime) {
        if self.phase == .armed {
            if let channels = self.audioConnection?.audioChannels {
                for channel in channels {
                    if channel.peakHoldLevel > -3.0 {
                        self.impactSoundTime = CACurrentMediaTime()
                    }
                }
            }
        }
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.phase == .searching { self.runAutoDetectionScan(on: pixelBuffer) }
            else if self.trackingObservation != nil { self.performVisionTracking(pixelBuffer: pixelBuffer, orientation: .up) }
        }
    }

    private func runAutoDetectionScan(on pixelBuffer: CVPixelBuffer) {
        guard let scanBox = autoScanVisionBox else { return }
        if self.trackingObservation == nil {
            self.trackingObservation = VNDetectedObjectObservation(boundingBox: scanBox)
            self.sequenceHandler = VNSequenceRequestHandler()
        }
        self.performVisionTracking(pixelBuffer: pixelBuffer, orientation: .up)
    }

    func startAutoDetection(atNormalizedViewPoint viewPoint: CGPoint) {
        if movieOutput.isRecording {
            self.lastCompositeData = nil
            movieOutput.stopRecording()
            DispatchQueue.main.async { self.onRecordingStateChanged?(false) }
        }
        guard let layer = previewLayer else { return }
        let pixelPoint = CGPoint(x: viewPoint.x * layer.bounds.width, y: viewPoint.y * layer.bounds.height)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: pixelPoint)
        let visionCenter = CGPoint(x: devicePoint.x, y: 1.0 - devicePoint.y)
        let boxWidth: CGFloat = 0.06
        let boxHeight: CGFloat = boxWidth * (16.0 / 9.0)
        self.autoScanVisionBox = CGRect(x: visionCenter.x - boxWidth/2, y: visionCenter.y - boxHeight/2, width: boxWidth, height: boxHeight)
        self.phase = .searching
        self.stabilityCounter = 0
        self.trackingObservation = nil
    }

    func armTracking(atPixelPoint viewPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        let visionCenter = CGPoint(x: devicePoint.x, y: 1.0 - devicePoint.y)
        let boxWidth: CGFloat = 0.05
        let boxHeight: CGFloat = boxWidth * (16.0 / 9.0)
        let visionBBox = CGRect(x: visionCenter.x - boxWidth/2, y: visionCenter.y - boxHeight/2, width: boxWidth, height: boxHeight)
        self.lockOn(visionBBox: visionBBox)
    }
    
    private func lockOn(visionBBox: CGRect) {
        trackingObservation = VNDetectedObjectObservation(boundingBox: visionBBox)
        sequenceHandler = VNSequenceRequestHandler()
        phase = .armed
        baselinePoint = nil
        shotStartTime = nil
        shotEndTime = nil
        impactSoundTime = nil
        overThresholdCount = 0
        trackingFrameCounter = 0
        activeTrackingFrames = 0
        
        self.initialBoxWidth = visionBBox.width
        self.initialBoxArea = visionBBox.width * visionBBox.height
        
        self.recordingStartTime = CACurrentMediaTime()
        DispatchQueue.main.async {
            if let layer = self.previewLayer {
                let viewNormRect = self.rectNormalizedInView(fromVisionBBox: visionBBox, layer: layer)
                self.onDebugBoundingBox?(viewNormRect)
            }
        }
        startRecording()
    }

    func stopTracking() {
        trackingObservation = nil
        self.phase = .idle
        if movieOutput.isRecording {
            self.lastCompositeData = nil
            movieOutput.stopRecording()
            DispatchQueue.main.async { self.onRecordingStateChanged?(false) }
        }
        DispatchQueue.main.async { self.onDebugBoundingBox?(nil) }
    }

    private func configureIfNeeded() {
        sessionQueue.sync {
            guard session.inputs.isEmpty else { return }
            session.beginConfiguration()
            if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
            if session.canAddInput(videoInput) { session.addInput(videoInput) }
            self.videoDevice = videoDevice
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                if session.canAddInput(audioInput) { session.addInput(audioInput) }
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.video.output.queue"))
            session.addOutput(videoOutput)
            let audioQueue = DispatchQueue(label: "camera.audio.queue")
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                self.audioConnection = audioOutput.connection(with: .audio)
            }
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
            self.configureHighFPS(for: videoDevice, targetFPS: 60.0)
            self.setZoom(scale: self.currentZoomScale)
        }
    }

    private func performVisionTracking(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard let currentObs = trackingObservation else { return }
        let request = VNTrackObjectRequest(detectedObjectObservation: currentObs)
        request.trackingLevel = .accurate
        try? sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        guard let result = request.results?.first as? VNDetectedObjectObservation,
              result.confidence >= self.minConfidence else {
            activeTrackingFrames = 0
            if self.phase != .searching { DispatchQueue.main.async { self.onDebugBoundingBox?(nil); self.handleLost() } }
            else { self.trackingObservation = nil; stabilityCounter = 0; DispatchQueue.main.async { self.onDebugBoundingBox?(nil) } }
            return
        }
        let visionBBox = result.boundingBox
        
        // ★ 修正: インパクト後は、速いボールに遅れないよう追跡ボックスを少し広げる (ROI動的拡張)
        if self.phase == .shotTracking {
            let expandedBox = visionBBox.insetBy(dx: -0.03, dy: -0.03)
            self.trackingObservation = VNDetectedObjectObservation(boundingBox: expandedBox)
        } else {
            self.trackingObservation = result
        }
        
        activeTrackingFrames += 1
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let layer = self.previewLayer else { return }
            let viewNormRect = self.rectNormalizedInView(fromVisionBBox: visionBBox, layer: layer)
            let centerPoint = CGPoint(x: viewNormRect.midX, y: viewNormRect.midY)
            if self.phase == .searching {
                let pixelWidth = viewNormRect.width * layer.bounds.width
                let pixelHeight = viewNormRect.height * layer.bounds.height
                let aspectRatio = pixelWidth / pixelHeight
                let widthRatio = viewNormRect.width
                if aspectRatio < 0.5 || aspectRatio > 2.0 || widthRatio < 0.02 || widthRatio > 0.25 {
                    self.trackingObservation = nil
                    stabilityCounter = 0
                    self.onDebugBoundingBox?(nil)
                    return
                }
                self.onDebugBoundingBox?(nil)
                self.checkStability(p: centerPoint, visionBBox: visionBBox)
            } else {
                self.onDebugBoundingBox?(viewNormRect)
                self.processPointUpdate(p: centerPoint, currentBBox: visionBBox)
            }
        }
    }

    private func checkStability(p: CGPoint, visionBBox: CGRect) {
        if let base = baselinePoint {
            if hypot(p.x - base.x, p.y - base.y) < 0.01 {
                stabilityCounter += 1
                if stabilityCounter > requiredStabilityFrames {
                    self.lockOn(visionBBox: visionBBox)
                    self.onAutoLockComplete?()
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                }
            } else { stabilityCounter = 0; baselinePoint = p }
        } else { baselinePoint = p }
    }

    private func processPointUpdate(p: CGPoint, currentBBox: CGRect) {
        switch self.phase {
        case .shotTracking:
            // ★ 修正: 「上方向に進まない点」や「横ブレ」は捨てる点群フィルタリング
            if let lastPt = baselinePoint {
                let movedUp = p.y < lastPt.y
                let notTooSideways = abs(p.x - lastPt.x) < 0.03
                let enoughMove = abs(p.y - lastPt.y) > 0.003
                
                if !(movedUp && enoughMove && notTooSideways) {
                    baselinePoint = nil
                    self.onShotEnded?()
                    return
                }
            }
            
            self.onTrackedPoint?(p)
            trackingFrameCounter += 1
            if trackingFrameCounter >= maxTrackingFrames { baselinePoint = nil; self.onShotEnded?(); return }
            if let base = baselinePoint {
                let dist = hypot(p.x - base.x, p.y - base.y)
                if dist < stopMoveThreshold { stopStabilityCounter += 1 } else { stopStabilityCounter = 0 }
                if stopStabilityCounter >= requiredStopFrames { baselinePoint = nil; self.onShotEnded?(); stopStabilityCounter = 0 }
            }
            baselinePoint = p
        case .armed:
            if baselinePoint == nil { baselinePoint = p }
            else if let base = baselinePoint {
                let currentArea = currentBBox.width * currentBBox.height
                let areaRatio = currentArea / (self.initialBoxArea > 0 ? self.initialBoxArea : 1.0)
                let widthRatio = currentBBox.width / (self.initialBoxWidth > 0 ? self.initialBoxWidth : 1.0)
                let isClubApproaching = areaRatio > 1.35 || widthRatio > 1.30
                let dist = hypot(p.x - base.x, p.y - base.y)
                let moved = dist > moveThreshold
                let heardImpact = (impactSoundTime != nil && (CACurrentMediaTime() - impactSoundTime! < 0.5))
                let isJustAddressing = isClubApproaching && (dist < 0.012 && !heardImpact)
                let isStableTracking = self.activeTrackingFrames >= 10
                
                if moved && !isJustAddressing && isStableTracking { overThresholdCount += 1 } else { overThresholdCount = 0 }
                
                if (overThresholdCount >= requiredConsecutive || (moved && heardImpact)) && !isJustAddressing && isStableTracking {
                    if !heardImpact {
                        print("🚫 [CameraManager] 大きな動きを検知しましたが、インパクト音がありません。無視します。")
                        overThresholdCount = 0
                    } else {
                        phase = .shotTracking
                        trackingFrameCounter = 0
                        shotStartTime = impactSoundTime ?? CACurrentMediaTime()
                        self.onShotBegan?()
                        self.onTrackedPoint?(p)
                        stopStabilityCounter = 0
                    }
                }
            }
            baselinePoint = p
        default: break
        }
    }

    private func rectNormalizedInView(fromVisionBBox visionBBox: CGRect, layer: AVCaptureVideoPreviewLayer) -> CGRect {
        let topLeftDevice = CGPoint(x: visionBBox.minX, y: 1.0 - visionBBox.maxY)
        let bottomRightDevice = CGPoint(x: visionBBox.maxX, y: 1.0 - visionBBox.minY)
        let topLeftView = layer.layerPointConverted(fromCaptureDevicePoint: topLeftDevice)
        let bottomRightView = layer.layerPointConverted(fromCaptureDevicePoint: bottomRightDevice)
        return CGRect(x: topLeftView.x / layer.bounds.width, y: topLeftView.y / layer.bounds.height, width: (bottomRightView.x - topLeftView.x) / layer.bounds.width, height: (bottomRightView.y - topLeftView.y) / layer.bounds.height)
    }

    private func handleLost() {
        if self.phase == .shotTracking { self.onShotEnded?() }
        else { trackingObservation = nil; self.onTrackingLost?() }
    }
    
    private func configureHighFPS(for device: AVCaptureDevice, targetFPS: Float64) {
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRateRange: AVFrameRateRange?
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= targetFPS {
                    if bestFormat == nil || range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                        bestFormat = format
                        bestFrameRateRange = range
                    }
                }
            }
        }
        if let format = bestFormat, let range = bestFrameRateRange {
            try? device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
        }
    }
}

// MARK: - Video Compositor with Rounded System Font & Centered Text Alignment
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error { return }
        guard let compData = self.lastCompositeData else { try? FileManager.default.removeItem(at: outputFileURL); return }
        self.compositeTracerAndSave(rawURL: outputFileURL, compData: compData)
    }
    
    private func compositeTracerAndSave(rawURL: URL, compData: CompositeData) {
        Task {
            let asset = AVAsset(url: rawURL)
            do {
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
                let size = try await videoTrack.load(.naturalSize); let transform = try await videoTrack.load(.preferredTransform); let timeRange = try await videoTrack.load(.timeRange)
                let renderSize = CGSize(width: abs(size.width * transform.a + size.height * transform.c), height: abs(size.width * transform.b + size.height * transform.d))
                let composition = AVMutableComposition(); guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
                try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                    if let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { try compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero) }
                }
                
                let parentLayer = CALayer(); parentLayer.frame = CGRect(origin: .zero, size: renderSize)
                let videoLayer = CALayer(); videoLayer.frame = parentLayer.bounds
                let overlayLayer = CALayer(); overlayLayer.frame = parentLayer.bounds
                parentLayer.addSublayer(videoLayer); parentLayer.addSublayer(overlayLayer)
                
                let tracerLayer = CAShapeLayer(); tracerLayer.frame = overlayLayer.bounds; tracerLayer.fillColor = UIColor.clear.cgColor; tracerLayer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.35, alpha: 1.0).cgColor; tracerLayer.lineWidth = 14.0; tracerLayer.lineCap = .round; tracerLayer.lineJoin = .round; tracerLayer.strokeEnd = 0.0
                
                var apexIndex = 0; var minNormalizedY: CGFloat = 1.0
                var totalLength: CGFloat = 0.0
                var dists: [CGFloat] = []
                var animDuration = compData.duration
                var timeToApex = 0.15
                var timeToDropPoint = 0.40
                
                if compData.points.count > 1 {
                    let path = UIBezierPath()
                    var prevMapped: CGPoint? = nil
                    for (i, p) in compData.points.enumerated() {
                        if p.y < minNormalizedY { minNormalizedY = p.y; apexIndex = i }
                        let mappedX = p.x * renderSize.width; let mappedY = (1.0 - p.y) * renderSize.height
                        let currMapped = CGPoint(x: mappedX, y: mappedY)
                        
                        if i == 0 {
                            path.move(to: currMapped)
                            dists.append(0.0)
                        } else {
                            path.addLine(to: currMapped)
                            let dist = hypot(currMapped.x - prevMapped!.x, currMapped.y - prevMapped!.y)
                            totalLength += dist
                            dists.append(totalLength)
                        }
                        prevMapped = currMapped
                    }
                    tracerLayer.path = path.cgPath
                    
                    if compData.carry < 6.0 {
                        animDuration = max(0.32, min(0.48, compData.carry * 0.09))
                    } else {
                        animDuration = max(1.5, min(3.5, compData.carry * 0.015))
                    }
                    
                    // ★ 修正: 究極の1発 Ease-Out でカクつきを完全排除
                    let animation = CAKeyframeAnimation(keyPath: "strokeEnd")
                    animation.values = [0.0, 1.0]
                    animation.keyTimes = [0.0, 1.0]
                    animation.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.1, 1.0, 0.4, 1.0)]
                    animation.duration = animDuration
                    animation.beginTime = AVCoreAnimationBeginTimeAtZero + compData.delay
                    animation.isRemovedOnCompletion = false
                    animation.fillMode = .both
                    
                    tracerLayer.add(animation, forKey: "drawTracer")
                    
                    let totalPoints = max(1, compData.points.count - 1)
                    let t_apex = Double(apexIndex) / Double(totalPoints)
                    timeToApex = max(0.05, t_apex * 0.40)
                    timeToDropPoint = timeToApex + (1.0 - timeToApex) * 0.45
                }
                overlayLayer.addSublayer(tracerLayer)
                
                let apexPointNorm = compData.points.indices.contains(apexIndex) ? compData.points[apexIndex] : CGPoint(x: 0.5, y: 0.4)
                let lastPointNorm = compData.points.last ?? CGPoint(x: 0.6, y: 0.6)
                let apexX = apexPointNorm.x * renderSize.width; let apexY = (1.0 - apexPointNorm.y) * renderSize.height
                let carryX = lastPointNorm.x * renderSize.width; let carryY = (1.0 - lastPointNorm.y) * renderSize.height
                let isTooClose = hypot(apexX - carryX, apexY - carryY) < (renderSize.width * 0.15)
                
                if compData.carry > 0 {
                    let text = String(format: "APEX  %.0f ft", compData.apex)
                    let bubble = self.createStyledBubbleLayer(text: text, gradientColors: [UIColor(red: 0.16, green: 0.38, blue: 0.64, alpha: 0.90).cgColor, UIColor(red: 0.08, green: 0.20, blue: 0.38, alpha: 0.95).cgColor], arrow: isTooClose ? .bottomRight : .right, renderSize: renderSize)
                    let finalX = isTooClose ? (apexX - bubble.bounds.width - 20) : (apexX - bubble.bounds.width - 15)
                    let finalY = isTooClose ? (apexY + 50) : (apexY + 20)
                    
                    let maxY = renderSize.height - (bubble.bounds.height / 2) - 10
                    var bubbleY = finalY + bubble.bounds.height / 2
                    if bubbleY > maxY { bubbleY = maxY }
                    
                    bubble.position = CGPoint(x: finalX + bubble.bounds.width/2, y: bubbleY)
                    
                    let apexShowTime = compData.delay + (animDuration * timeToApex)
                    self.addAnimationToLayer(bubble, beginTime: apexShowTime); overlayLayer.addSublayer(bubble)
                }
                
                if compData.carry > 0 {
                    let text = String(format: "BALL SPEED %.1f m/s  /  LAUNCH %.1f°", compData.speed, compData.launch)
                    let bubble = self.createStyledBubbleLayer(text: text, gradientColors: [UIColor(red: 0.10, green: 0.25, blue: 0.45, alpha: 0.85).cgColor, UIColor(red: 0.05, green: 0.12, blue: 0.25, alpha: 0.90).cgColor], arrow: .left, renderSize: renderSize)
                    let firstPt = compData.points.first ?? CGPoint(x:0.5, y:0.8); let startX = firstPt.x * renderSize.width; let startY = (1.0 - firstPt.y) * renderSize.height
                    bubble.position = CGPoint(x: startX + 15 + bubble.bounds.width/2, y: startY - 30 + bubble.bounds.height/2)
                    
                    self.addAnimationToLayer(bubble, beginTime: compData.delay + 0.05); overlayLayer.addSublayer(bubble)
                }

                if compData.carry > 0 {
                    let text = String(format: "CARRY %.0f yds", compData.carry)
                    let bubble = self.createStyledBubbleLayer(text: text, gradientColors: [UIColor(red: 0.12, green: 0.42, blue: 0.22, alpha: 0.90).cgColor, UIColor(red: 0.05, green: 0.22, blue: 0.10, alpha: 0.95).cgColor], arrow: isTooClose ? .left : .bottom, renderSize: renderSize)
                    let finalX = isTooClose ? (carryX + 15) : (carryX - bubble.bounds.width * 0.5); let finalY = isTooClose ? (carryY - bubble.bounds.height * 0.5) : (carryY + 30)
                    bubble.position = CGPoint(x: finalX + bubble.bounds.width/2, y: finalY + bubble.bounds.height/2)
                    
                    let carryShowTime = compData.delay + (animDuration * timeToDropPoint)
                    self.addAnimationToLayer(bubble, beginTime: carryShowTime); overlayLayer.addSublayer(bubble)
                }
                
                let videoComp = AVMutableVideoComposition(); videoComp.renderSize = renderSize; videoComp.frameDuration = CMTime(value: 1, timescale: 60)
                let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = timeRange; let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack); layerInstruction.setTransform(transform, at: .zero); instruction.layerInstructions = [layerInstruction]
                videoComp.instructions = [instruction] as [AVVideoCompositionInstructionProtocol]
                videoComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_composite.mp4")
                guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return }
                export.videoComposition = videoComp; export.outputURL = outURL; export.outputFileType = .mp4
                await export.export(); if export.status == .completed { self.saveToPhotos(url: outURL) }; try? FileManager.default.removeItem(at: rawURL)
            } catch { }
        }
    }

    private func createStyledBubbleLayer(text: String, gradientColors: [CGColor], arrow: ArrowDirection, renderSize: CGSize) -> CALayer {
        let fontSize = renderSize.height * 0.026
        let systemFont = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let roundedFont: UIFont
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) { roundedFont = UIFont(descriptor: descriptor, size: fontSize) } else { roundedFont = systemFont }
        let attributes: [NSAttributedString.Key: Any] = [.font: roundedFont]
        let textSize = (text as NSString).size(withAttributes: attributes)
        
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 16
        let bubbleWidth = textSize.width + horizontalPadding
        let bubbleHeight = textSize.height + verticalPadding
        
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        
        let bg = CAGradientLayer()
        bg.frame = container.bounds
        bg.colors = gradientColors
        bg.cornerRadius = 8
        bg.startPoint = CGPoint(x: 0, y: 0)
        bg.endPoint = CGPoint(x: 1, y: 1)
        container.addSublayer(bg)
        
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = roundedFont
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2.0
        textLayer.frame = CGRect(x: 0, y: (bubbleHeight - textSize.height) / 2.0, width: bubbleWidth, height: textSize.height)
        container.addSublayer(textLayer)
        
        let arrowLayer = CAShapeLayer()
        let arrowPath = UIBezierPath()
        let arrowSize: CGFloat = 12
        switch arrow {
        case .left:
            arrowPath.move(to: CGPoint(x: 0, y: 5)); arrowPath.addLine(to: CGPoint(x: -arrowSize, y: bubbleHeight/2)); arrowPath.addLine(to: CGPoint(x: 0, y: bubbleHeight-5))
            arrowLayer.frame = CGRect(x: 0, y: 0, width: arrowSize, height: bubbleHeight)
        case .right:
            arrowPath.move(to: CGPoint(x: 0, y: 5)); arrowPath.addLine(to: CGPoint(x: arrowSize, y: bubbleHeight/2)); arrowPath.addLine(to: CGPoint(x: 0, y: bubbleHeight-5))
            arrowLayer.frame = CGRect(x: bubbleWidth, y: 0, width: arrowSize, height: bubbleHeight)
        case .bottom:
            arrowPath.move(to: CGPoint(x: 5, y: 0)); arrowPath.addLine(to: CGPoint(x: bubbleWidth/2, y: -arrowSize)); arrowPath.addLine(to: CGPoint(x: bubbleWidth-5, y: 0))
            arrowLayer.frame = CGRect(x: 0, y: 0, width: bubbleWidth, height: arrowSize)
        case .bottomRight:
            arrowPath.move(to: CGPoint(x: bubbleWidth-10, y: 0)); arrowPath.addLine(to: CGPoint(x: bubbleWidth+10, y: -arrowSize)); arrowPath.addLine(to: CGPoint(x: bubbleWidth, y: 10))
            arrowLayer.frame = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        }
        arrowPath.close(); arrowLayer.path = arrowPath.cgPath; arrowLayer.fillColor = gradientColors.first; container.addSublayer(arrowLayer)
        return container
    }
    
    private func addAnimationToLayer(_ layer: CALayer, beginTime: Double) {
        layer.opacity = 0.0; let anim = CABasicAnimation(keyPath: "opacity"); anim.fromValue = 0.0; anim.toValue = 1.0; anim.duration = 0.15; anim.beginTime = AVCoreAnimationBeginTimeAtZero + beginTime; anim.isRemovedOnCompletion = false; anim.fillMode = .both; layer.add(anim, forKey: "show")
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }) { saved, _ in
                if saved { DispatchQueue.main.async { self.onVideoSaved?() } }
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from conn: AVCaptureConnection) {
        if output == self.videoOutput {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard let pix = CMSampleBufferGetImageBuffer(buffer) else { return }
            processExternalBuffer(pix, orientation: .up, time: timestamp)
        }
    }
}
