//
//  MeasurementViewModel.swift
//  ShotTracerMVP
//
//  以前のUI（MeasurementScreen.swift）互換 of 最小構成版
//

import Foundation
import AVFoundation
import Vision
import CoreGraphics
import Combine
import SwiftUI
import UIKit
import Photos

class MeasurementViewModel: ObservableObject {
    @Published var hintText: String = "カメラをボールに向けてください"
    @Published var phase: TrackingPhase = .idle
    @Published var metrics = ShotMetrics()
    @Published var tracerPointsNormalized: [CGPoint] = []
    @Published var isTapEnabled: Bool = true
    @Published var aimPointNormalized: CGPoint? = nil
    @Published var selectedClub: String = "Toy/Indoor" {
        didSet { updateClubPhysics() }
    }
    
    @Published var isRecording: Bool = false
    @Published var videoThumbnail: UIImage? = nil
    @Published var debugBoundingBoxNormalized: CGRect? = nil
    @Published var currentZoomScale: CGFloat = 1.0
    
    private var lockedBallCenter: CGPoint? = nil
    private var videoShotTime: Double = 0.0
    private var simulatedHangTime: Double = 5.5 // 物理シミュレーションによる実際の滞空時間を保持
    
    // 参考動画風のマゼンタスタイル
    let tracerColor: Color = Color(red: 0.9, green: 0.1, blue: 0.4) // マゼンタレッド
    let tracerOpacity: Double = 0.90
    let tracerWidth: CGFloat = 8.0
    let tracerGlowWidth: CGFloat = 16.0
    let tracerGlowOpacity: Double = 0.4
    let tracerGlowBlur: CGFloat = 6.0

    enum TrackingPhase: String {
        case idle = "IDLE"
        case searching = "SCANNING"
        case armed = "READY"
        case shotTracking = "TRACKING"
    }

    struct ShotMetrics {
        var carryYards: Double = 0
        var launchDeg: Double = 0
        var directionDeg: Double = 0
        var ballSpeedMS: Double = 0
        var apexFeet: Double = 0
    }

    let camera = CameraManager()
    private var currentVideoURL: URL?
    private var isVideoMode: Bool = false
    
    // =====================================================================
    // ★ 物理幾何学定数 (ゴルフボール仕様 & 空力定数)
    // =====================================================================
    private let g: Double = 9.80665      // 重力加速度 (m/s^2)
    private let rho: Double = 1.204      // 常温時の空気密度 (kg/m^3)
    private let mass: Double = 0.04593   // 公認球の規格重量 (kg)
    private let r: Double = 0.021335     // 公認球の規格半径 (m)
    private var area: Double { .pi * r * r }
    
    private var targetCd: Double = 0.22  // 空力抗力係数 (Cd値)
    private var expectedSpin: Double = 3000.0 // 推定初期スピン量 (rpm)
    private var spinDecayRate: Double = 12.0 // スピン減衰定数 (秒)

    init() {
        setupCallbacks()
        updateClubPhysics()
    }

    private func updateClubPhysics() {
        if selectedClub == "Toy/Indoor" {
            targetCd = 0.45; expectedSpin = 1000.0
        } else if selectedClub == "Driver" {
            targetCd = 0.21; expectedSpin = 2400.0
        } else if selectedClub == "PW" || selectedClub == "SW" {
            targetCd = 0.25; expectedSpin = 9000.0
        } else if selectedClub == "9I" {
            targetCd = 0.24; expectedSpin = 8000.0
        } else if selectedClub.contains("W") {
            targetCd = 0.22; expectedSpin = 3500.0
        } else if selectedClub == "7I" {
            targetCd = 0.23; expectedSpin = 6000.0
        } else {
            targetCd = 0.24; expectedSpin = 7500.0
        }
    }

    func resetTracer() {
        tracerPointsNormalized.removeAll()
        camera.pointsToDraw.removeAll()
        metrics = ShotMetrics()
        phase = .idle
        hintText = isVideoMode ? "動画内のボールをタップしてください" : "ボールをタップ、またはAuto Modeを開始"
        aimPointNormalized = nil
        debugBoundingBoxNormalized = nil
        lockedBallCenter = nil
        videoShotTime = 0.0
        camera.stopTracking()
        if !isVideoMode { videoThumbnail = nil }
    }

    func armTracking(atPixelPoint point: CGPoint) {
        if isVideoMode {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let normPoint = self.aimPointNormalized else { return }
                self.lockedBallCenter = normPoint
                let boxWidth: CGFloat = 0.05
                let boxHeight: CGFloat = boxWidth * (16.0 / 9.0)
                self.debugBoundingBoxNormalized = CGRect(x: normPoint.x - boxWidth/2, y: normPoint.y - boxHeight/2, width: boxWidth, height: boxHeight)
                self.phase = .armed
                self.hintText = "動画を解析中..."
                if let url = self.currentVideoURL { self.runVideoAnalysisLoop(at: url) }
            }
        } else {
            self.aimPointNormalized = point
            self.lockedBallCenter = point
            let boxWidth: CGFloat = 0.05
            let boxHeight: CGFloat = boxWidth * (16.0 / 9.0)
            self.debugBoundingBoxNormalized = CGRect(x: point.x - boxWidth/2, y: point.y - boxHeight/2, width: boxWidth, height: boxHeight)
            camera.armTracking(atPixelPoint: point)
            self.phase = .armed
            self.hintText = "準備完了（手動ロック）"
        }
    }

    func startAutoMode() {
        self.resetTracer()
        self.phase = .searching
        self.hintText = "点線の枠内にボールを置いてください"
        camera.startAutoDetection(atNormalizedViewPoint: CGPoint(x: 0.5, y: 0.65))
    }
    
    func setZoom(scale: CGFloat) {
        self.currentZoomScale = scale
        camera.setZoom(scale: scale)
    }

    func forceEndAndSave() {
        guard phase == .shotTracking else { return }
        self.runBallisticSimulation()
        self.phase = .idle
        self.hintText = "計測完了（手動）：弾道を予測保存します"
        
        if isVideoMode, let rawURL = currentVideoURL {
            exportImportedVideo(rawURL: rawURL)
        } else {
            self.camera.stopRecordingWithMetrics(carry: self.metrics.carryYards, speed: self.metrics.ballSpeedMS, launch: self.metrics.launchDeg, apex: self.metrics.apexFeet)
        }
    }

    func prepareVideoAnalysis(at url: URL) {
        self.currentVideoURL = url
        self.isVideoMode = true
        self.camera.stop()
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, result, error in
            if let error = error { print("Thumbnail Generation Error: \(error)"); return }
            guard let cgImage = cgImage, result == .succeeded else { return }
            let uiImage = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                self?.videoThumbnail = uiImage
                self?.resetTracer()
                self?.hintText = "動画内のボールをタップして解析開始"
                self?.isTapEnabled = true
            }
        }
    }

    private func getAverageColor(from pixelBuffer: CVPixelBuffer, in rectNormalized: CGRect) -> (r: Float, g: Float, b: Float)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let heightReal = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        let startX = max(0, Int(rectNormalized.minX * CGFloat(width)))
        let startY = max(0, Int((1.0 - rectNormalized.maxY) * CGFloat(heightReal)))
        let endX = min(width - 1, Int(rectNormalized.maxX * CGFloat(width)))
        let endY = min(heightReal - 1, Int((1.0 - rectNormalized.minY) * CGFloat(heightReal)))
        
        guard startX < endX && startY < endY else { return nil }
        var sumR: Int = 0, sumG: Int = 0, sumB: Int = 0, count: Int = 0
        
        for y in startY...endY {
            let rowData = baseAddress.advanced(by: y * bytesPerRow)
            for x in startX...endX {
                let offset = x * 4
                sumB += Int(rowData.load(fromByteOffset: offset, as: UInt8.self))
                sumG += Int(rowData.load(fromByteOffset: offset + 1, as: UInt8.self))
                sumR += Int(rowData.load(fromByteOffset: offset + 2, as: UInt8.self))
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (Float(sumR) / Float(count), Float(sumG) / Float(count), Float(sumB) / Float(count))
    }

    private func calculateColorDifference(color1: (r: Float, g: Float, b: Float), color2: (r: Float, g: Float, b: Float)) -> Float {
        let diffR = abs(color1.r - color2.r)
        let diffG = abs(color1.g - color2.g)
        let diffB = abs(color1.b - color2.b)
        return (diffR + diffG + diffB) / (255.0 * 3.0)
    }

    // =====================================================================
    // ★ 映像解析メインループ
    // =====================================================================
    private func runVideoAnalysisLoop(at url: URL) {
        let initialPoint = self.aimPointNormalized ?? CGPoint(x: 0.5, y: 0.72)
        let boxWidth: CGFloat = 0.04
        let boxHeight: CGFloat = boxWidth * (16.0 / 9.0)
        let visionBBox = CGRect(x: initialPoint.x - boxWidth/2, y: (1.0 - initialPoint.y) - boxHeight/2, width: boxWidth, height: boxHeight)
        
        var currentObservation: VNDetectedObjectObservation? = VNDetectedObjectObservation(boundingBox: visionBBox)
        var sequenceHandler = VNSequenceRequestHandler()
        
        var trackingFrameCount = 0
        var debugFrameCount = 0
        var firstTimestamp: Double? = nil
        
        var lastCenter = initialPoint
        var recentPoints: [CGPoint] = []
        
        var initialVisionBBox: CGRect? = nil
        var initialBallColor: (r: Float, g: Float, b: Float)? = nil
        var previousTrackerColor: (r: Float, g: Float, b: Float)? = nil
        var recentOriginColorDiffs: [Float] = []
        
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else { return }
                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                reader.add(trackOutput)
                if !reader.startReading() { return }
                
                print("\n================== 動画解析開始 ==================")
                
                while reader.status == .reading {
                    var observationResult: VNDetectedObjectObservation? = nil
                    var currentPts: CMTime? = nil
                    var isBufferValid = false
                    var originColorDiff: Float = 0.0
                    var trackerColorDiff: Float = 0.0
                    
                    autoreleasepool {
                        if let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                            isBufferValid = true
                            currentPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                                if let obs = currentObservation {
                                    let request = VNTrackObjectRequest(detectedObjectObservation: obs)
                                    request.trackingLevel = .accurate
                                    try? sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
                                    observationResult = request.results?.first as? VNDetectedObjectObservation
                                }
                                
                                if initialVisionBBox == nil {
                                    initialVisionBBox = visionBBox
                                    initialBallColor = self.getAverageColor(from: pixelBuffer, in: visionBBox)
                                }
                                if let initBox = initialVisionBBox, let refColor = initialBallColor {
                                    if let currOriginColor = self.getAverageColor(from: pixelBuffer, in: initBox) {
                                        originColorDiff = self.calculateColorDifference(color1: currOriginColor, color2: refColor)
                                    }
                                }
                                if let result = observationResult {
                                    if let currTrackerColor = self.getAverageColor(from: pixelBuffer, in: result.boundingBox) {
                                        if let prevColor = previousTrackerColor { trackerColorDiff = self.calculateColorDifference(color1: currTrackerColor, color2: prevColor) }
                                        previousTrackerColor = currTrackerColor
                                    }
                                }
                            }
                        }
                    }
                    
                    if !isBufferValid { break }
                    guard let pts = currentPts else { continue }
                    
                    debugFrameCount += 1
                    let currentSecs = CMTimeGetSeconds(pts)
                    if firstTimestamp == nil { firstTimestamp = currentSecs }
                    let relativeTime = currentSecs - (firstTimestamp ?? currentSecs)
                    
                    let phaseNow = await MainActor.run { self.phase }
                    guard phaseNow == .armed || phaseNow == .shotTracking else { break }
                    
                    if let result = observationResult, result.confidence > 0.15 {
                        let center = CGPoint(x: result.boundingBox.midX, y: 1.0 - result.boundingBox.midY)
                        var shouldResetTracker = false
                        
                        await MainActor.run {
                            self.debugBoundingBoxNormalized = CGRect(x: center.x - result.boundingBox.width/2, y: center.y - result.boundingBox.height/2, width: result.boundingBox.width, height: result.boundingBox.height)
                            
                            if self.phase == .armed {
                                let startPt = self.lockedBallCenter ?? initialPoint
                                let dyFromStart = startPt.y - center.y
                                let dyFromLast = center.y - lastCenter.y
                                let dyUpwardFromLast = lastCenter.y - center.y
                                let dxFromStart = center.x - startPt.x
                                
                                recentOriginColorDiffs.append(originColorDiff)
                                if recentOriginColorDiffs.count > 5 { recentOriginColorDiffs.removeFirst() }
                                let maxOriginColorDiff = recentOriginColorDiffs.max() ?? 0.0
                                
                                let isAnomalyMove = dyFromStart < -0.015 || abs(center.x - startPt.x) > 0.15 || dyFromLast > 0.02
                                let isColorChanged = trackerColorDiff > 0.08
                                
                                if isAnomalyMove || isColorChanged {
                                    let dyFromStartAtLast = startPt.y - lastCenter.y
                                    var stationaryFramesAtLastCenter = 0
                                    for pt in recentPoints.reversed() { if hypot(pt.x - lastCenter.x, pt.y - lastCenter.y) < 0.005 { stationaryFramesAtLastCenter += 1 } else { break } }
                                    let distFromStartAtLast = hypot(lastCenter.x - startPt.x, startPt.y - lastCenter.y)
                                    let isSuspiciousStationary = (distFromStartAtLast > 0.005) && (stationaryFramesAtLastCenter >= 5)
                                    
                                    if dyFromStartAtLast >= 0.005 && abs(lastCenter.x - startPt.x) < 0.08 {
                                        if maxOriginColorDiff >= 0.008 && !isSuspiciousStationary {
                                            self.phase = .shotTracking
                                            self.hintText = "ショット検知！弾道をシミュレーション中..."
                                            self.tracerPointsNormalized.removeAll()
                                            self.tracerPointsNormalized.append(startPt)
                                            let filterRate = self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                                            var lastRawPt = startPt
                                            for pt in recentPoints {
                                                let dy = lastRawPt.y - pt.y
                                                let dx = abs(pt.x - lastRawPt.x)
                                                if dy > 0.002 && pt.y >= lastCenter.y && dx < dy * 5.0 {
                                                    self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (pt.x - startPt.x) * filterRate, y: pt.y))
                                                    lastRawPt = pt
                                                }
                                            }
                                            let finalDy = lastRawPt.y - lastCenter.y
                                            let finalDx = abs(lastCenter.x - lastRawPt.x)
                                            if finalDy > 0.002 && finalDx < finalDy * 5.0 { self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (lastCenter.x - startPt.x) * filterRate, y: lastCenter.y)) }
                                            self.videoShotTime = relativeTime - 0.05
                                            observationResult = nil
                                            shouldResetTracker = false
                                        } else { shouldResetTracker = true }
                                    } else { shouldResetTracker = true }
                                } else {
                                    recentPoints.append(center)
                                    if recentPoints.count > 15 { recentPoints.removeFirst() }
                                    
                                    if dyFromStart > 0.024 {
                                        let isCurrentlyMovingUp = dyUpwardFromLast > 0.005
                                        let isVerticalDominant = abs(dxFromStart) < dyFromStart * 2.5
                                        var framesSinceMoved = 0
                                        for pt in recentPoints.reversed() { if (startPt.y - pt.y) > 0.01 { framesSinceMoved += 1 } else { break } }
                                        
                                        let isBallMissing = maxOriginColorDiff >= 0.010
                                        let isFastMove = framesSinceMoved > 0 && framesSinceMoved <= 2
                                        
                                        if isBallMissing && isFastMove && isCurrentlyMovingUp && isVerticalDominant {
                                            self.phase = .shotTracking
                                            self.hintText = "ショット検知！弾道をシミュレーション中..."
                                            self.tracerPointsNormalized.removeAll()
                                            self.tracerPointsNormalized.append(startPt)
                                            let filterRate = self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                                            var lastRawPt = startPt
                                            for pt in recentPoints {
                                                let dy = lastRawPt.y - pt.y
                                                let dx = abs(pt.x - lastRawPt.x)
                                                if dy > 0.002 && pt.y >= center.y && dx < dy * 5.0 {
                                                    self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (pt.x - startPt.x) * filterRate, y: pt.y))
                                                    lastRawPt = pt
                                                }
                                            }
                                            let finalDy = lastRawPt.y - center.y
                                            let finalDx = abs(center.x - lastRawPt.x)
                                            if finalDy > 0.002 && finalDx < finalDy * 5.0 { self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (center.x - startPt.x) * filterRate, y: center.y)) }
                                            self.videoShotTime = relativeTime - (Double(framesSinceMoved) / 60.0)
                                        } else { shouldResetTracker = true }
                                    }
                                }
                            } else if self.phase == .shotTracking {
                                trackingFrameCount += 1
                                var filteredCenter = center
                                if let startPt = self.lockedBallCenter {
                                    let dx = center.x - startPt.x
                                    let filterRate = self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                                    filteredCenter = CGPoint(x: startPt.x + dx * filterRate, y: center.y)
                                }
                                
                                // ★ 修正: インパクト直後は信頼度が下がるので閾値を 0.25 に緩和
                                if result.confidence < 0.25 || trackerColorDiff > 0.08 {
                                    observationResult = nil
                                } else if let lastPt = self.tracerPointsNormalized.last {
                                    // ★ 修正: 「上方向に進まない点」「横ブレ」は採用せず予測へ移行
                                    let movedUp = filteredCenter.y < lastPt.y
                                    let notTooSideways = abs(filteredCenter.x - lastPt.x) < 0.03
                                    let enoughMove = abs(lastPt.y - filteredCenter.y) > 0.003
                                    
                                    if movedUp && enoughMove && notTooSideways {
                                        self.tracerPointsNormalized.append(filteredCenter)
                                    } else {
                                        observationResult = nil
                                    }
                                } else {
                                    self.tracerPointsNormalized.append(filteredCenter)
                                }
                                
                                if trackingFrameCount >= 4 { observationResult = nil }
                            }
                        }
                        
                        if shouldResetTracker {
                            currentObservation = VNDetectedObjectObservation(boundingBox: visionBBox)
                            lastCenter = initialPoint
                            recentPoints.removeAll()
                            sequenceHandler = VNSequenceRequestHandler()
                            previousTrackerColor = nil
                            recentOriginColorDiffs.removeAll()
                        } else {
                            if self.phase == .shotTracking && trackingFrameCount >= 4 {
                                currentObservation = nil
                            } else if self.phase == .shotTracking && observationResult != nil {
                                // ★ 修正: 動画モードでも、速いボールに遅れないよう追跡ボックスを広げる
                                let expandedBox = observationResult!.boundingBox.insetBy(dx: -0.03, dy: -0.03)
                                currentObservation = VNDetectedObjectObservation(boundingBox: expandedBox)
                            } else {
                                currentObservation = result
                            }
                            lastCenter = center
                        }
                        
                    } else {
                        var isSavedByRescue = false
                        await MainActor.run {
                            if self.phase == .armed {
                                let startPt = self.lockedBallCenter ?? initialPoint
                                let dyFromStart = startPt.y - lastCenter.y
                                recentOriginColorDiffs.append(originColorDiff)
                                if recentOriginColorDiffs.count > 5 { recentOriginColorDiffs.removeFirst() }
                                let updatedMaxDiff = recentOriginColorDiffs.max() ?? 0.0
                                var stationaryFramesAtLastCenter = 0
                                for pt in recentPoints.reversed() { if hypot(pt.x - lastCenter.x, pt.y - lastCenter.y) < 0.005 { stationaryFramesAtLastCenter += 1 } else { break } }
                                let distFromStart = hypot(lastCenter.x - startPt.x, startPt.y - lastCenter.y)
                                let isSuspiciousStationary = (distFromStart > 0.005) && (stationaryFramesAtLastCenter >= 5)
                                
                                if dyFromStart >= -0.008 && abs(lastCenter.x - startPt.x) < 0.08 {
                                    if updatedMaxDiff >= 0.008 && !isSuspiciousStationary {
                                        isSavedByRescue = true
                                        self.phase = .shotTracking
                                        self.hintText = "ショット検知！弾道をシミュレーション中..."
                                        self.tracerPointsNormalized.removeAll()
                                        self.tracerPointsNormalized.append(startPt)
                                        let filterRate = self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                                        var lastRawPt = startPt
                                        for pt in recentPoints {
                                            let dy = lastRawPt.y - pt.y
                                            let dx = abs(pt.x - lastRawPt.x)
                                            if dy > 0.002 && pt.y >= lastCenter.y && dx < dy * 5.0 {
                                                self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (pt.x - startPt.x) * filterRate, y: pt.y))
                                                lastRawPt = pt
                                            }
                                        }
                                        let finalDy = lastRawPt.y - lastCenter.y
                                        let finalDx = abs(lastCenter.x - lastRawPt.x)
                                        if finalDy > 0.002 && finalDx < finalDy * 5.0 { self.tracerPointsNormalized.append(CGPoint(x: startPt.x + (lastCenter.x - startPt.x) * filterRate, y: lastCenter.y)) }
                                        self.videoShotTime = relativeTime - 0.05
                                    }
                                }
                            }
                        }
                        if isSavedByRescue {
                            currentObservation = nil
                        } else {
                            let phaseNow2 = await MainActor.run { self.phase }
                            if phaseNow2 == .armed {
                                await MainActor.run {
                                    currentObservation = VNDetectedObjectObservation(boundingBox: visionBBox)
                                    lastCenter = initialPoint
                                    recentPoints.removeAll()
                                    sequenceHandler = VNSequenceRequestHandler()
                                    previousTrackerColor = nil
                                    recentOriginColorDiffs.removeAll()
                                }
                            } else {
                                currentObservation = nil
                            }
                        }
                    }
                    if currentObservation == nil && phaseNow == .shotTracking { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                
                await MainActor.run {
                    if self.phase == .armed {
                        self.hintText = "検知できませんでした。もう一度タップしてください。"
                        self.phase = .idle
                        self.debugBoundingBoxNormalized = nil
                    } else if self.phase == .shotTracking {
                        self.forceEndAndSave()
                    }
                }
            } catch {
                await MainActor.run { self.hintText = "動画の読み込みエラーが発生しました"; self.phase = .idle }
            }
        }
    }

    private func setupCallbacks() {
        camera.onDebugBoundingBox = { [weak self] viewNormBox in
            DispatchQueue.main.async {
                self?.debugBoundingBoxNormalized = viewNormBox
                if self?.phase == .armed, self?.lockedBallCenter == nil, let box = viewNormBox { self?.lockedBallCenter = CGPoint(x: box.midX, y: box.midY) }
            }
        }
        camera.onAutoLockComplete = { [weak self] in
            DispatchQueue.main.async {
                self?.phase = .armed; self?.hintText = "ロック＆録画開始！いつでも打てます"
                if let box = self?.debugBoundingBoxNormalized { self?.lockedBallCenter = CGPoint(x: box.midX, y: box.midY) }
            }
        }
        camera.onRecordingStateChanged = { [weak self] isRec in DispatchQueue.main.async { self?.isRecording = isRec } }
        camera.onVideoSaved = { [weak self] in DispatchQueue.main.async { self?.hintText = "動画をカメラロールに保存しました！" } }
        camera.onTrackedPoint = { [weak self] point in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.phase == .shotTracking else { return }
                var filteredPoint = point
                if let startPt = self.lockedBallCenter {
                    let dx = point.x - startPt.x; let filterRate = self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                    filteredPoint = CGPoint(x: startPt.x + dx * filterRate, y: point.y)
                }
                if self.tracerPointsNormalized.isEmpty, let startPt = self.lockedBallCenter { self.tracerPointsNormalized.append(startPt) }
                self.tracerPointsNormalized.append(filteredPoint)
                self.camera.pointsToDraw = self.tracerPointsNormalized
            }
        }
        camera.onShotBegan = { [weak self] in DispatchQueue.main.async { self?.phase = .shotTracking; self?.hintText = "ショット検知！弾道をシミュレーション中..." } }
        camera.onShotEnded = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.runBallisticSimulation()
                self.phase = .idle; self.hintText = "計測完了！動画を合成保存します..."
                if self.isVideoMode, let rawURL = self.currentVideoURL { self.exportImportedVideo(rawURL: rawURL) } else { self.camera.stopRecordingWithMetrics(carry: self.metrics.carryYards, speed: self.metrics.ballSpeedMS, launch: self.metrics.launchDeg, apex: self.metrics.apexFeet) }
            }
        }
        camera.onTrackingLost = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.phase == .shotTracking {
                    self.runBallisticSimulation(); self.phase = .idle; self.hintText = "計測完了（途切れ）：先を予測保存します"
                    if self.isVideoMode, let rawURL = self.currentVideoURL { self.exportImportedVideo(rawURL: rawURL) } else { self.camera.stopRecordingWithMetrics(carry: self.metrics.carryYards, speed: self.metrics.ballSpeedMS, launch: self.metrics.launchDeg, apex: self.metrics.apexFeet) }
                } else if self.phase == .searching {
                    self.phase = .idle; self.hintText = "ボールを見失いました"; self.debugBoundingBoxNormalized = nil
                }
            }
        }
    }

    private func runBallisticSimulation() {
        // ★ 修正: ノイズの多い最初の数点を捨て、確実に上方向へ離れた「安定した複数点」を抽出してベクトルを計算する
        guard let startPt = lockedBallCenter ?? tracerPointsNormalized.first else { return }
        
        var validPoints: [CGPoint] = [startPt]
        for pt in tracerPointsNormalized {
            // ボールの初期位置から上に 0.005 (0.5%) 以上離れている点のみを採用
            if pt.y < startPt.y - 0.005 {
                validPoints.append(pt)
            }
        }
        
        // ベクトル計算
        var vx: CGFloat = 0.0
        var vy: CGFloat = 0.0
        
        if validPoints.count >= 3 {
            // 安定した最初の2点（startPtの次はvalidPoints[1], その次はvalidPoints[2]）を使用
            let p1 = validPoints[1]
            let p2 = validPoints[2]
            
            vx = p2.x - p1.x
            vy = p1.y - p2.y // 上方向を正
            
            self.tracerPointsNormalized = [startPt, p1]
            
        } else if validPoints.count == 2 {
            // 有効な点が2つしかない場合
            let p1 = validPoints[0]
            let p2 = validPoints[1]
            vx = p2.x - p1.x
            vy = p1.y - p2.y
            
            self.tracerPointsNormalized = [p1]
        } else if let lb = lockedBallCenter {
            // 有効な点が無い場合のフォールバック
            self.tracerPointsNormalized = [lb]
            vx = 0.0
            vy = 0.015 // デフォルトの上昇
        }
        
        // ★ 修正: ベクトルが異常な値（極端に真横や真下）にならないように補正
        if vy < 0.001 { vy = 0.005 } // 最低限の上昇を確保
        vx = max(-0.02, min(0.02, vx)) // 極端な横ブレを制限（より真っ直ぐ飛ばす）
        
        // 予測ポイントの生成（真っ直ぐ伸びてから、重力でアーチを描く）
        var predictedPoints: [CGPoint] = []
        var maxH = 0.0
        
        for i in 1...100 {
            let t = CGFloat(i)
            // 重力の効き具合を微調整（デフォルメされた綺麗な落下を作る）
            let gravity: CGFloat = 0.00015 * t * t
            
            let predicted = CGPoint(
                x: (self.tracerPointsNormalized.last?.x ?? startPt.x) + vx * t * 1.5,
                y: (self.tracerPointsNormalized.last?.y ?? startPt.y) - vy * t * 1.5 + gravity
            )
            
            // 画面の最下部（地面）を超えたら計算終了
            if predicted.y > 0.95 { break }
            
            if (1.0 - predicted.y) > maxH { maxH = (1.0 - predicted.y) }
            predictedPoints.append(predicted)
        }
        
        // メトリクスの計算 (予測されたベクトルから計算)
        let screenSpeed = hypot(Double(vx), Double(vy)) * 60.0
        self.metrics.ballSpeedMS = max(20.0, min(80.0, screenSpeed * 2.5))
        self.metrics.launchDeg = max(8.0, min(35.0, atan2(Double(vy), abs(Double(vx))) * 180.0 / .pi))
        
        // CARRY と APEX は簡単な比例で計算 (必要に応じて調整)
        self.metrics.carryYards = self.metrics.ballSpeedMS * 3.5
        self.metrics.apexFeet = maxH * 300.0 // 画面上の最高点から計算
        self.simulatedHangTime = 4.0
        
        self.tracerPointsNormalized.append(contentsOf: predictedPoints)
        self.camera.pointsToDraw = self.tracerPointsNormalized
    }
    
    private func firstRealPointCoordinate() -> CGPoint { return self.lockedBallCenter ?? self.aimPointNormalized ?? CGPoint(x: 0.5, y: 0.72) }
}

// MARK: - インポート動画専用のエクスポート処理
extension MeasurementViewModel {
    private func exportImportedVideo(rawURL: URL) {
        let compDataPoints = self.tracerPointsNormalized; let carry = self.metrics.carryYards; let speed = self.metrics.ballSpeedMS; let launch = self.metrics.launchDeg; let apex = self.metrics.apexFeet
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
                let tracerLayer = CAShapeLayer(); tracerLayer.frame = overlayLayer.bounds; tracerLayer.fillColor = UIColor.clear.cgColor; tracerLayer.strokeColor = UIColor(red: 0.9, green: 0.1, blue: 0.4, alpha: 0.90).cgColor; tracerLayer.lineWidth = 20.0; tracerLayer.lineCap = .round; tracerLayer.lineJoin = .round; tracerLayer.strokeEnd = 0.0
                
                let adjustedShotTime = max(0.0, self.videoShotTime - 0.03)
                let animDuration = max(2.0, min(4.5, self.simulatedHangTime * 0.8))
                var apexIndex = 0; var minNormalizedY: CGFloat = 1.0; var totalLength: CGFloat = 0.0; var dists: [CGFloat] = []
                
                if compDataPoints.count > 1 {
                    let path = UIBezierPath(); var prevMapped: CGPoint? = nil
                    for (i, p) in compDataPoints.enumerated() {
                        if p.y < minNormalizedY { minNormalizedY = p.y; apexIndex = i }
                        let mappedX = p.x * renderSize.width; let mappedY = (1.0 - p.y) * renderSize.height; let currMapped = CGPoint(x: mappedX, y: mappedY)
                        if i == 0 { path.move(to: currMapped); dists.append(0.0) } else { path.addLine(to: currMapped); totalLength += hypot(currMapped.x - prevMapped!.x, currMapped.y - prevMapped!.y); dists.append(totalLength) }
                        prevMapped = currMapped
                    }
                    tracerLayer.path = path.cgPath
                    
                    // ★ 修正: 全てを単一の美しい減速カーブに統合してカクつきを完全排除
                    let animation = CAKeyframeAnimation(keyPath: "strokeEnd")
                    animation.values = [0.0, 1.0]
                    animation.keyTimes = [0.0, 1.0]
                    // 究極の1発 Ease-Out (打ち出しは超高速で直線的、後半にかけて一度も止まることなく滑らかに減速)
                    animation.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.1, 1.0, 0.4, 1.0)]
                    animation.duration = animDuration
                    animation.beginTime = AVCoreAnimationBeginTimeAtZero + adjustedShotTime
                    animation.isRemovedOnCompletion = false
                    animation.fillMode = .both
                    tracerLayer.add(animation, forKey: "drawTracer")
                }
                overlayLayer.addSublayer(tracerLayer)
                
                let apexPointNorm = compDataPoints.indices.contains(apexIndex) ? compDataPoints[apexIndex] : CGPoint(x: 0.5, y: 0.4); let lastPointNorm = compDataPoints.last ?? CGPoint(x: 0.6, y: 0.6)
                let apexX = apexPointNorm.x * renderSize.width; let apexY = (1.0 - apexPointNorm.y) * renderSize.height
                let carryX = lastPointNorm.x * renderSize.width; let carryY = (1.0 - lastPointNorm.y) * renderSize.height; let isTooClose = hypot(apexX - carryX, apexY - carryY) < (renderSize.width * 0.15)
                
                // バブル出現の動的計算（1カーブの進行度に合わせる）
                let totalPoints = max(1, compDataPoints.count - 1)
                let t_apex = Double(apexIndex) / Double(totalPoints)
                let timeToApex = max(0.05, t_apex * 0.40)
                let timeToDropPoint = timeToApex + (1.0 - timeToApex) * 0.45
                
                if carry > 0 {
                    let bubble = createStyledBubbleLayer(text: String(format: "APEX  %.0f ft", apex), gradientColors: [UIColor(red: 0.16, green: 0.38, blue: 0.64, alpha: 0.90).cgColor, UIColor(red: 0.08, green: 0.20, blue: 0.38, alpha: 0.95).cgColor], renderSize: renderSize)
                    let finalX = isTooClose ? (apexX - bubble.bounds.width - 20) : (apexX - bubble.bounds.width - 15); let finalY = isTooClose ? (apexY + 50) : (apexY + 20)
                    var bubbleY = finalY + bubble.bounds.height / 2; if bubbleY > renderSize.height - (bubble.bounds.height / 2) - 10 { bubbleY = renderSize.height - (bubble.bounds.height / 2) - 10 }
                    bubble.position = CGPoint(x: finalX + bubble.bounds.width/2, y: bubbleY)
                    self.addAnimationToLayer(bubble, beginTime: adjustedShotTime + (animDuration * timeToApex)); overlayLayer.addSublayer(bubble)
                }
                if carry > 0 {
                    let bubble = createStyledBubbleLayer(text: String(format: "BALL SPEED %.1f m/s  /  LAUNCH %.1f°", speed, launch), gradientColors: [UIColor(red: 0.10, green: 0.25, blue: 0.45, alpha: 0.85).cgColor, UIColor(red: 0.05, green: 0.12, blue: 0.25, alpha: 0.90).cgColor], renderSize: renderSize)
                    let firstPt = compDataPoints.first ?? CGPoint(x:0.5, y:0.8); bubble.position = CGPoint(x: firstPt.x * renderSize.width + 15 + bubble.bounds.width/2, y: (1.0 - firstPt.y) * renderSize.height - 30 + bubble.bounds.height/2)
                    self.addAnimationToLayer(bubble, beginTime: adjustedShotTime + 0.05); overlayLayer.addSublayer(bubble)
                }
                if carry > 0 {
                    let bubble = createStyledBubbleLayer(text: String(format: "CARRY %.0f yds", carry), gradientColors: [UIColor(red: 0.12, green: 0.42, blue: 0.22, alpha: 0.90).cgColor, UIColor(red: 0.05, green: 0.22, blue: 0.10, alpha: 0.95).cgColor], renderSize: renderSize)
                    let finalX = isTooClose ? (carryX + 15) : (carryX - bubble.bounds.width * 0.5); let finalY = isTooClose ? (carryY - bubble.bounds.height * 0.5) : (carryY + 30)
                    bubble.position = CGPoint(x: finalX + bubble.bounds.width/2, y: finalY + bubble.bounds.height/2)
                    self.addAnimationToLayer(bubble, beginTime: adjustedShotTime + (animDuration * timeToDropPoint)); overlayLayer.addSublayer(bubble)
                }
                
                let videoComp = AVMutableVideoComposition(); videoComp.renderSize = renderSize; videoComp.frameDuration = CMTime(value: 1, timescale: 60)
                let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = timeRange; let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack); layerInstruction.setTransform(transform, at: .zero); instruction.layerInstructions = [layerInstruction]
                videoComp.instructions = [instruction] as [AVVideoCompositionInstructionProtocol]
                videoComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
                
                let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_import_composite.mp4")
                guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return }
                export.videoComposition = videoComp; export.outputURL = outURL; export.outputFileType = .mp4
                await export.export(); if export.status == .completed { self.saveToPhotos(url: outURL) } else { DispatchQueue.main.async { self.hintText = "動画の合成に失敗しました" } }
            } catch { DispatchQueue.main.async { self.hintText = "保存処理エラー" } }
        }
    }
    
    private func createStyledBubbleLayer(text: String, gradientColors: [CGColor], renderSize: CGSize) -> CALayer {
        let fontSize = renderSize.height * 0.026; let systemFont = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let roundedFont: UIFont = { if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: descriptor, size: fontSize) } else { return systemFont } }()
        let attributes: [NSAttributedString.Key: Any] = [.font: roundedFont]; let textSize = (text as NSString).size(withAttributes: attributes)
        let bubbleWidth = textSize.width + 24; let bubbleHeight = textSize.height + 16
        let container = CALayer(); container.bounds = CGRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        let bg = CAGradientLayer(); bg.frame = container.bounds; bg.colors = gradientColors; bg.cornerRadius = 8; bg.startPoint = CGPoint(x: 0, y: 0); bg.endPoint = CGPoint(x: 1, y: 1); container.addSublayer(bg)
        let textLayer = CATextLayer(); textLayer.string = text; textLayer.font = roundedFont; textLayer.fontSize = fontSize; textLayer.foregroundColor = UIColor.white.cgColor; textLayer.alignmentMode = .center; textLayer.contentsScale = 2.0
        textLayer.frame = CGRect(x: 0, y: (bubbleHeight - textSize.height) / 2.0, width: bubbleWidth, height: textSize.height); container.addSublayer(textLayer)
        return container
    }
    
    private func addAnimationToLayer(_ layer: CALayer, beginTime: Double) {
        layer.opacity = 0.0; let anim = CABasicAnimation(keyPath: "opacity"); anim.fromValue = 0.0; anim.toValue = 1.0; anim.duration = 0.15; anim.beginTime = AVCoreAnimationBeginTimeAtZero + beginTime; anim.isRemovedOnCompletion = false; anim.fillMode = .both; layer.add(anim, forKey: "show")
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }) { saved, _ in DispatchQueue.main.async { self.hintText = saved ? "動画をカメラロールに保存しました！" : "保存に失敗しました" } }
        }
    }
}
