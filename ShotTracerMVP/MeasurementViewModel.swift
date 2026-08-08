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
    
    private struct ClubTrajectoryProfile {
        // インパクト直後の直線区間
        let laserDuration: CGFloat

        // 直線区間の上方向への伸び
        let laserVerticalScale: CGFloat

        // 頂点へ移行するまでの時間
        let climbDuration: CGFloat

        // 頂点までの追加上昇量に掛ける倍率
        let additionalRiseScale: CGFloat

        // 頂点までの最低上昇量
        let minimumAdditionalRise: CGFloat

        // 頂点までの最大上昇量
        let maximumAdditionalRise: CGFloat

        // 頂点後の落下加速度
        let fallGravity: CGFloat

        // 横方向の伸び
        let horizontalScale: CGFloat

        // 頂点へ向かう横方向の減速率
        let climbHorizontalRate: CGFloat

        // 頂点後の横方向の減速率
        let fallHorizontalRate: CGFloat
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
    
    private func trajectoryProfile(
        for club: String
    ) -> ClubTrajectoryProfile {
        switch club {
        case "Driver":
            return ClubTrajectoryProfile(
                laserDuration: 0.22,
                laserVerticalScale: 0.78,
                climbDuration: 0.62,
                additionalRiseScale: 0.10,
                minimumAdditionalRise: 0.07,
                maximumAdditionalRise: 0.22,
                fallGravity: 0.42,
                horizontalScale: 1.00,
                climbHorizontalRate: 0.80,
                fallHorizontalRate: 0.75
            )

        case "3W":
            return ClubTrajectoryProfile(
                laserDuration: 0.20,
                laserVerticalScale: 0.82,
                climbDuration: 0.64,
                additionalRiseScale: 0.11,
                minimumAdditionalRise: 0.08,
                maximumAdditionalRise: 0.23,
                fallGravity: 0.44,
                horizontalScale: 0.95,
                climbHorizontalRate: 0.76,
                fallHorizontalRate: 0.70
            )

        case "5W":
            return ClubTrajectoryProfile(
                laserDuration: 0.18,
                laserVerticalScale: 0.86,
                climbDuration: 0.67,
                additionalRiseScale: 0.12,
                minimumAdditionalRise: 0.09,
                maximumAdditionalRise: 0.24,
                fallGravity: 0.46,
                horizontalScale: 0.90,
                climbHorizontalRate: 0.72,
                fallHorizontalRate: 0.66
            )

        case "7I":
            return ClubTrajectoryProfile(
                laserDuration: 0.16,
                laserVerticalScale: 0.94,
                climbDuration: 0.68,
                additionalRiseScale: 0.14,
                minimumAdditionalRise: 0.11,
                maximumAdditionalRise: 0.27,
                fallGravity: 0.50,
                horizontalScale: 0.82,
                climbHorizontalRate: 0.66,
                fallHorizontalRate: 0.58
            )

        case "9I":
            return ClubTrajectoryProfile(
                laserDuration: 0.14,
                laserVerticalScale: 1.00,
                climbDuration: 0.70,
                additionalRiseScale: 0.16,
                minimumAdditionalRise: 0.13,
                maximumAdditionalRise: 0.29,
                fallGravity: 0.54,
                horizontalScale: 0.74,
                climbHorizontalRate: 0.60,
                fallHorizontalRate: 0.52
            )

        case "PW":
            return ClubTrajectoryProfile(
                laserDuration: 0.12,
                laserVerticalScale: 1.08,
                climbDuration: 0.72,
                additionalRiseScale: 0.18,
                minimumAdditionalRise: 0.15,
                maximumAdditionalRise: 0.31,
                fallGravity: 0.58,
                horizontalScale: 0.66,
                climbHorizontalRate: 0.54,
                fallHorizontalRate: 0.46
            )

        case "SW":
            return ClubTrajectoryProfile(
                laserDuration: 0.10,
                laserVerticalScale: 1.15,
                climbDuration: 0.74,
                additionalRiseScale: 0.20,
                minimumAdditionalRise: 0.17,
                maximumAdditionalRise: 0.33,
                fallGravity: 0.62,
                horizontalScale: 0.58,
                climbHorizontalRate: 0.48,
                fallHorizontalRate: 0.40
            )

        case "Toy/Indoor":
            return ClubTrajectoryProfile(
                laserDuration: 0.10,
                laserVerticalScale: 0.90,
                climbDuration: 0.45,
                additionalRiseScale: 0.10,
                minimumAdditionalRise: 0.06,
                maximumAdditionalRise: 0.18,
                fallGravity: 0.65,
                horizontalScale: 0.55,
                climbHorizontalRate: 0.50,
                fallHorizontalRate: 0.42
            )

        default:
            return ClubTrajectoryProfile(
                laserDuration: 0.16,
                laserVerticalScale: 0.90,
                climbDuration: 0.60,
                additionalRiseScale: 0.12,
                minimumAdditionalRise: 0.08,
                maximumAdditionalRise: 0.24,
                fallGravity: 0.50,
                horizontalScale: 0.85,
                climbHorizontalRate: 0.65,
                fallHorizontalRate: 0.60
            )
        }
    }
    
    func resetTracer() {
        tracerPointsNormalized.removeAll()
        camera.pointsToDraw.removeAll()

        metrics = ShotMetrics()
        phase = .idle

        hintText = isVideoMode
            ? "動画内のボールをタップしてください"
            : "ボールをタップ、またはAuto Modeを開始"

        aimPointNormalized = nil
        debugBoundingBoxNormalized = nil
        lockedBallCenter = nil
        videoShotTime = 0.0

        camera.stopTracking()

        if !isVideoMode {
            videoThumbnail = nil
        }
    }

    func armTracking(atPixelPoint point: CGPoint) {
        if isVideoMode {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let normPoint = self.aimPointNormalized else { return }
                self.lockedBallCenter = normPoint
                let boxWidth: CGFloat = 0.05
                let boxHeight: CGFloat = 0.05

                self.debugBoundingBoxNormalized = CGRect(
                    x: normPoint.x - boxWidth / 2,
                    y: normPoint.y - boxHeight / 2,
                    width: boxWidth,
                    height: boxHeight
                )
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
        let boxWidth: CGFloat = 0.05
        let boxHeight: CGFloat = 0.05
        let rawVisionBBox = CGRect(
            x: initialPoint.x - boxWidth / 2,
            y: (1.0 - initialPoint.y) - boxHeight / 2,
            width: boxWidth,
            height: boxHeight
        )
        
        let visionBBox = rawVisionBBox.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        
        var currentObservation: VNDetectedObjectObservation? = VNDetectedObjectObservation(boundingBox: visionBBox)
        var sequenceHandler = VNSequenceRequestHandler()
        
        var trackingFrameCount = 0
        var debugFrameCount = 0
        var firstTimestamp: Double? = nil
        
        // インパクト後の実測追跡用
        var invalidTrackingFrames = 0
        
        // ショット検知後に採用できた有効点の数
        var postImpactValidPointCount = 0
        var shouldFinishPostImpactTracking = false
        
        let maxInvalidTrackingFrames = 3
        let maxPostImpactTrackingFrames = 6
        
        // 予測へ移行するために必要な有効点数
        let requiredPostImpactValidPoints = 3
        
        var lastCenter = initialPoint
        var recentPoints: [CGPoint] = []
        
        var initialVisionBBox: CGRect? = nil
        var initialBallColor: (r: Float, g: Float, b: Float)? = nil
        var previousTrackerColor: (r: Float, g: Float, b: Float)? = nil
        var recentOriginColorDiffs: [Float] = []
        
        // 原点の色変化が連続したフレーム数
        var consecutiveOriginChangedFrames = 0

        // 上方向へ連続移動したフレーム数
        var consecutiveUpwardMoveFrames = 0

        // 開始位置から離れた場所でVisionが静止したフレーム数
        var consecutiveFrozenAwayFrames = 0

        // Visionが開始位置付近で固定されたまま、
        // 原点の色だけが大きく変化したフレーム数
        var consecutiveImpactDisappearFrames = 0

        // Rescueを許可する最低条件
        let requiredOriginChangedFrames = 3
        let requiredUpwardMoveFrames = 3
        
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
                                    do {
                                        try sequenceHandler.perform(
                                            [request],
                                            on: pixelBuffer,
                                            orientation: .up
                                        )

                                        observationResult =
                                            request.results?.first
                                            as? VNDetectedObjectObservation

                                    } catch {
                                        print(
                                            "❌ Vision tracking error: \(error)"
                                        )

                                        observationResult = nil
                                    }
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
                    
                    if debugFrameCount % 30 == 0 {
                        print(
                            """
                            🎞 FRAME CHECK
                            frame: \(debugFrameCount)
                            time: \(currentSecs)
                            readerStatus: \(reader.status.rawValue)
                            hasCurrentObservation: \(currentObservation != nil)
                            hasObservationResult: \(observationResult != nil)
                            """
                        )
                    }
                    
                    let phaseNow =
                        await MainActor.run {
                            self.phase
                        }

                    guard phaseNow == .armed ||
                          phaseNow == .shotTracking else {

                        print(
                            """
                            🛑 VIDEO LOOP STOPPED BY PHASE
                            frame: \(debugFrameCount)
                            time: \(relativeTime)
                            phase: \(phaseNow.rawValue)
                            """
                        )

                        break
                    }
                    
                    if debugFrameCount % 10 == 0 {
                        if let result = observationResult {
                            let center = CGPoint(
                                x: result.boundingBox.midX,
                                y: 1.0 - result.boundingBox.midY
                            )

                            print(
                                """
                                🔎 VISION RESULT
                                frame: \(debugFrameCount)
                                time: \(relativeTime)
                                confidence: \(result.confidence)
                                centerX: \(center.x)
                                centerY: \(center.y)
                                bboxWidth: \(result.boundingBox.width)
                                bboxHeight: \(result.boundingBox.height)
                                originColorDiff: \(originColorDiff)
                                trackerColorDiff: \(trackerColorDiff)
                                """
                            )
                        } else {
                            print(
                                """
                                ⚠️ VISION RESULT NIL
                                frame: \(debugFrameCount)
                                time: \(relativeTime)
                                hasCurrentObservation: \(currentObservation != nil)
                                originColorDiff: \(originColorDiff)
                                """
                            )
                        }
                    }
                    
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
                                
                                let movementFromLast = hypot(
                                    center.x - lastCenter.x,
                                    center.y - lastCenter.y
                                )

                                let distanceFromStart = hypot(
                                    center.x - startPt.x,
                                    center.y - startPt.y
                                )

                                // 開始位置から離れている状態で、ほぼ動かない場合を数える
                                if distanceFromStart > 0.025 &&
                                    movementFromLast < 0.001 {

                                    consecutiveFrozenAwayFrames += 1
                                } else {
                                    consecutiveFrozenAwayFrames = 0
                                }

                                let isTrackerFrozenAwayFromStart =
                                    consecutiveFrozenAwayFrames >= 3
                                
                                if isTrackerFrozenAwayFromStart {
                                    print(
                                        """
                                        ♻️ TRACKER RESET: frozen away from start
                                        time: \(relativeTime)
                                        frozenFrames: \(consecutiveFrozenAwayFrames)
                                        distanceFromStart: \(distanceFromStart)
                                        movementFromLast: \(movementFromLast)
                                        centerX: \(center.x)
                                        centerY: \(center.y)
                                        """
                                    )

                                    shouldResetTracker = true
                                }
                                
                                // 開始位置の近くで、Visionの追跡枠がほぼ停止しているか
                                let isTrackerFrozenNearStart =
                                    distanceFromStart <= 0.025 &&
                                    movementFromLast < 0.001

                                // 原点の色がインパクト相当まで大きく変化したか
                                let hasStrongOriginChange =
                                    originColorDiff >= 0.015

                                if isTrackerFrozenNearStart &&
                                    hasStrongOriginChange {

                                    consecutiveImpactDisappearFrames += 1
                                } else {
                                    consecutiveImpactDisappearFrames = 0
                                }

                                // 2フレーム連続した場合に、
                                // インパクトによってボールが消えた候補とする
                                let isImpactDisappearCandidate =
                                    consecutiveImpactDisappearFrames >= 2
                                
                                if hasStrongOriginChange ||
                                    consecutiveImpactDisappearFrames > 0 {

                                    print(
                                        """
                                        💥 IMPACT DISAPPEAR CANDIDATE
                                        time: \(relativeTime)
                                        distanceFromStart: \(distanceFromStart)
                                        movementFromLast: \(movementFromLast)
                                        originDiff: \(originColorDiff)
                                        impactFrames: \(consecutiveImpactDisappearFrames)
                                        frozenNearStart: \(isTrackerFrozenNearStart)
                                        strongOriginChange: \(hasStrongOriginChange)
                                        confirmed: \(isImpactDisappearCandidate)
                                        confidence: \(result.confidence)
                                        """
                                    )
                                }
                                
                                // 原点の色が変化し続けているか
                                if originColorDiff >= 0.010 {
                                    consecutiveOriginChangedFrames += 1
                                } else {
                                    consecutiveOriginChangedFrames = 0
                                }
                                
                                // Vision上の対象が連続して上へ移動しているか
                                if dyUpwardFromLast >= 0.003 {
                                    consecutiveUpwardMoveFrames += 1
                                } else {
                                    consecutiveUpwardMoveFrames = 0
                                }
                                
                                recentOriginColorDiffs.append(originColorDiff)
                                if recentOriginColorDiffs.count > 5 { recentOriginColorDiffs.removeFirst() }
                                
                                let isAnomalyMove = dyFromStart < -0.015 || abs(center.x - startPt.x) > 0.15 || dyFromLast > 0.02
                                let isColorChanged = trackerColorDiff > 0.08
                                
                                if isAnomalyMove || isColorChanged {
                                    let dyFromStartAtLast = startPt.y - lastCenter.y
                                    var stationaryFramesAtLastCenter = 0
                                    for pt in recentPoints.reversed() { if hypot(pt.x - lastCenter.x, pt.y - lastCenter.y) < 0.005 { stationaryFramesAtLastCenter += 1 } else { break } }
                                    let distFromStartAtLast = hypot(lastCenter.x - startPt.x, startPt.y - lastCenter.y)
                                    let isSuspiciousStationary = (distFromStartAtLast > 0.005) && (stationaryFramesAtLastCenter >= 5)
                                    
                                    let hasEnoughUpwardDisplacement =
                                    dyFromStartAtLast >= 0.010
                                    
                                    let horizontalMovementIsReasonable =
                                    abs(lastCenter.x - startPt.x) < 0.06
                                    
                                    let originChangedContinuously =
                                    consecutiveOriginChangedFrames >=
                                    requiredOriginChangedFrames
                                    
                                    let movedUpContinuously =
                                    consecutiveUpwardMoveFrames >=
                                    requiredUpwardMoveFrames
                                    
                                    let hasUsableUpwardPoint =
                                    recentPoints.contains { point in
                                        let upwardDistance =
                                        startPt.y - point.y
                                        
                                        let horizontalDistance =
                                        abs(point.x - startPt.x)
                                        
                                        return upwardDistance >= 0.008 &&
                                        horizontalDistance <
                                            max(
                                                upwardDistance * 3.0,
                                                0.03
                                            )
                                    }
                                    
                                    print(
                                        """
                                        🧪 ANOMALY CANDIDATE
                                        time: \(relativeTime)
                                        isAnomalyMove: \(isAnomalyMove)
                                        isColorChanged: \(isColorChanged)
                                        hasEnoughUpwardDisplacement: \(hasEnoughUpwardDisplacement)
                                        horizontalMovementIsReasonable: \(horizontalMovementIsReasonable)
                                        originChangedContinuously: \(originChangedContinuously)
                                        movedUpContinuously: \(movedUpContinuously)
                                        hasUsableUpwardPoint: \(hasUsableUpwardPoint)
                                        isSuspiciousStationary: \(isSuspiciousStationary)
                                        originFrames: \(consecutiveOriginChangedFrames)
                                        upwardFrames: \(consecutiveUpwardMoveFrames)
                                        dyFromStart: \(dyFromStart)
                                        dyFromStartAtLast: \(dyFromStartAtLast)
                                        dyFromLast: \(dyFromLast)
                                        dxFromStart: \(dxFromStart)
                                        originDiff: \(originColorDiff)
                                        trackerDiff: \(trackerColorDiff)
                                        confidence: \(result.confidence)
                                        """
                                    )
                                    
                                    if hasEnoughUpwardDisplacement &&
                                        horizontalMovementIsReasonable &&
                                        originChangedContinuously &&
                                        movedUpContinuously &&
                                        hasUsableUpwardPoint &&
                                        !isSuspiciousStationary &&
                                        !isTrackerFrozenAwayFromStart {
                                        
                                        print(
                                            """
                                            🚨 SHOT ROUTE: imported-anomaly
                                            time: \(relativeTime)
                                            originFrames: \(consecutiveOriginChangedFrames)
                                            upwardFrames: \(consecutiveUpwardMoveFrames)
                                            dyFromStart: \(dyFromStart)
                                            dyFromStartAtLast: \(dyFromStartAtLast)
                                            dyFromLast: \(dyFromLast)
                                            dxFromStart: \(dxFromStart)
                                            originDiff: \(originColorDiff)
                                            trackerDiff: \(trackerColorDiff)
                                            confidence: \(result.confidence)
                                            bboxWidth: \(result.boundingBox.width)
                                            bboxHeight: \(result.boundingBox.height)
                                            """
                                        )
                                        
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
                                        
                                        trackingFrameCount = 0
                                        invalidTrackingFrames = 0
                                        postImpactValidPointCount = 0
                                        shouldFinishPostImpactTracking = false
                                        
                                        shouldResetTracker = false
                                    } else {
                                        // 明確に不正な方向へ移動した場合だけ追跡をリセットする
                                        let clearlyInvalidMovement =
                                        dyFromStart < -0.015 ||
                                        abs(dxFromStart) > 0.15
                                        
                                        shouldResetTracker =
                                            shouldResetTracker ||
                                            clearlyInvalidMovement
                                    }
                                } else {
                                    recentPoints.append(center)
                                    if recentPoints.count > 15 { recentPoints.removeFirst() }
                                    
                                    if dyFromStart > 0.024 {
                                        let isCurrentlyMovingUp = dyUpwardFromLast > 0.005
                                        let isVerticalDominant = abs(dxFromStart) < dyFromStart * 2.5
                                        var framesSinceMoved = 0
                                        for pt in recentPoints.reversed() { if (startPt.y - pt.y) > 0.01 { framesSinceMoved += 1 } else { break } }
                                        
                                        let isBallMissing =
                                        consecutiveOriginChangedFrames >=
                                        requiredOriginChangedFrames
                                        
                                        let isFastMove =
                                        framesSinceMoved > 0 &&
                                        framesSinceMoved <= 3
                                        
                                        let hasEnoughUpwardDisplacement =
                                        dyFromStart >= 0.024
                                        
                                        let hasConsecutiveUpwardMovement =
                                        consecutiveUpwardMoveFrames >=
                                        requiredUpwardMoveFrames
                                        
                                        print(
                                            """
                                            🧪 NORMAL CANDIDATE
                                            time: \(relativeTime)
                                            isBallMissing: \(isBallMissing)
                                            isFastMove: \(isFastMove)
                                            hasEnoughUpwardDisplacement: \(hasEnoughUpwardDisplacement)
                                            hasConsecutiveUpwardMovement: \(hasConsecutiveUpwardMovement)
                                            isCurrentlyMovingUp: \(isCurrentlyMovingUp)
                                            isVerticalDominant: \(isVerticalDominant)
                                            originFrames: \(consecutiveOriginChangedFrames)
                                            upwardFrames: \(consecutiveUpwardMoveFrames)
                                            framesSinceMoved: \(framesSinceMoved)
                                            dyFromStart: \(dyFromStart)
                                            dyFromLast: \(dyFromLast)
                                            dxFromStart: \(dxFromStart)
                                            originDiff: \(originColorDiff)
                                            trackerDiff: \(trackerColorDiff)
                                            """
                                        )
                                        
                                        if isBallMissing &&
                                            isFastMove &&
                                            hasEnoughUpwardDisplacement &&
                                            hasConsecutiveUpwardMovement &&
                                            isCurrentlyMovingUp &&
                                            isVerticalDominant &&
                                            !isTrackerFrozenAwayFromStart {
                                            
                                            print(
                                                """
                                                🚨 SHOT ROUTE: imported-normal
                                                originFrames: \(consecutiveOriginChangedFrames)
                                                upwardFrames: \(consecutiveUpwardMoveFrames)
                                                dyFromStart: \(dyFromStart)
                                                dxFromStart: \(dxFromStart)
                                                originDiff: \(originColorDiff)
                                                trackerDiff: \(trackerColorDiff)
                                                """
                                            )

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
                                            self.videoShotTime =
                                            relativeTime -
                                            (Double(framesSinceMoved) / 60.0)
                                            
                                            trackingFrameCount = 0
                                            invalidTrackingFrames = 0
                                            postImpactValidPointCount = 0
                                            shouldFinishPostImpactTracking = false
                                            
                                            shouldResetTracker = false
                                            
                                        } else {
                                            let clearlyInvalidMovement =
                                            dyFromStart < -0.015 ||
                                            abs(dxFromStart) > 0.15
                                            
                                            shouldResetTracker =
                                                shouldResetTracker ||
                                                clearlyInvalidMovement
                                        }
                                    }
                                }
                            } else if self.phase == .shotTracking {
                                trackingFrameCount += 1
                                
                                var filteredCenter = center
                                
                                if let startPt = self.lockedBallCenter {
                                    let dxFromStart = center.x - startPt.x
                                    let filterRate: CGFloat =
                                    self.selectedClub == "Toy/Indoor" ? 0.2 : 0.3
                                    
                                    filteredCenter = CGPoint(
                                        x: startPt.x + dxFromStart * filterRate,
                                        y: center.y
                                    )
                                }
                                
                                var isValidTrackingPoint = true
                                
                                // 高速移動中は一時的に信頼度が低下するため、
                                // 1回の低下では追跡を終了しない
                                if result.confidence < 0.20 {
                                    isValidTrackingPoint = false
                                }
                                
                                // 高速ボールはブラーで色が変わるため、
                                // armed時より緩い条件にする
                                if trackerColorDiff > 0.16 {
                                    isValidTrackingPoint = false
                                }
                                
                                if let lastPt = self.tracerPointsNormalized.last {
                                    let deltaX = filteredCenter.x - lastPt.x
                                    let deltaY = filteredCenter.y - lastPt.y
                                    
                                    let horizontalMove = abs(deltaX)
                                    let verticalMove = abs(deltaY)
                                    let totalMove = hypot(deltaX, deltaY)
                                    
                                    let directionIsAcceptable: Bool
                                    
                                    if trackingFrameCount <= 3 {
                                        // 左上原点なので、上方向はdeltaYがマイナス。
                                        // 0.002未満の小さな下方向ノイズまでは許容する。
                                        directionIsAcceptable = deltaY < 0.002
                                    } else {
                                        directionIsAcceptable = true
                                    }
                                    
                                    let moveIsLargeEnough =
                                    totalMove > 0.0015
                                    
                                    let moveIsNotExcessive =
                                    totalMove < 0.10
                                    
                                    let horizontalMoveIsReasonable =
                                    horizontalMove < 0.05 ||
                                    horizontalMove < max(
                                        verticalMove * 6.0,
                                        0.015
                                    )
                                    
                                    if !directionIsAcceptable ||
                                        !moveIsLargeEnough ||
                                        !moveIsNotExcessive ||
                                        !horizontalMoveIsReasonable {
                                        
                                        isValidTrackingPoint = false
                                    }
                                }
                                
                                var didAppendPostImpactPoint = false
                                
                                if isValidTrackingPoint {
                                    if let lastPt = self.tracerPointsNormalized.last {
                                        let distance = hypot(
                                            filteredCenter.x - lastPt.x,
                                            filteredCenter.y - lastPt.y
                                        )
                                        
                                        if distance > 0.0015 {
                                            self.tracerPointsNormalized.append(
                                                filteredCenter
                                            )
                                            
                                            postImpactValidPointCount += 1
                                            didAppendPostImpactPoint = true
                                            
                                            print(
                                                "✅ インパクト後の有効点 " +
                                                "\(postImpactValidPointCount)/" +
                                                "\(requiredPostImpactValidPoints) " +
                                                "distance:\(distance)"
                                            )
                                        }
                                        
                                    } else {
                                        self.tracerPointsNormalized.append(
                                            filteredCenter
                                        )
                                        
                                        postImpactValidPointCount += 1
                                        didAppendPostImpactPoint = true
                                        
                                        print(
                                            "✅ インパクト後の最初の有効点 " +
                                            "\(postImpactValidPointCount)/" +
                                            "\(requiredPostImpactValidPoints)"
                                        )
                                    }
                                }
                                
                                if didAppendPostImpactPoint {
                                    invalidTrackingFrames = 0
                                    
                                } else {
                                    invalidTrackingFrames += 1
                                    
                                    print(
                                        "⚠️ インパクト後の無効点 " +
                                        "\(invalidTrackingFrames)/" +
                                        "\(maxInvalidTrackingFrames) " +
                                        "confidence:\(result.confidence) " +
                                        "colorDiff:\(trackerColorDiff)"
                                    )
                                }
                                
                                let hasEnoughMeasuredPoints =
                                postImpactValidPointCount >=
                                requiredPostImpactValidPoints
                                
                                let reachedFrameLimit =
                                trackingFrameCount >=
                                maxPostImpactTrackingFrames
                                
                                let reachedInvalidLimit =
                                invalidTrackingFrames >=
                                maxInvalidTrackingFrames
                                
                                if reachedFrameLimit ||
                                    reachedInvalidLimit ||
                                    hasEnoughMeasuredPoints {
                                    
                                    print(
                                        "🏁 実測追跡を終了 " +
                                        "frames:\(trackingFrameCount) " +
                                        "validPoints:\(postImpactValidPointCount) " +
                                        "invalid:\(invalidTrackingFrames)"
                                    )
                                    
                                    shouldFinishPostImpactTracking = true
                                }
                            }
                        }
                        
                        if shouldResetTracker {
                            currentObservation =
                                VNDetectedObjectObservation(
                                    boundingBox: visionBBox
                                )

                            lastCenter = initialPoint
                            recentPoints.removeAll()

                            sequenceHandler =
                                VNSequenceRequestHandler()

                            previousTrackerColor = nil
                            recentOriginColorDiffs.removeAll()

                            consecutiveOriginChangedFrames = 0
                            consecutiveUpwardMoveFrames = 0
                            consecutiveFrozenAwayFrames = 0
                            consecutiveImpactDisappearFrames = 0
                        } else {
                            if self.phase == .shotTracking &&
                                shouldFinishPostImpactTracking {
                                
                                currentObservation = nil
                                
                            } else if self.phase == .shotTracking,
                                      let shotObservation = observationResult {
                                
                                let originalBox = shotObservation.boundingBox
                                
                                let maximumWidth: CGFloat = 0.14
                                let maximumHeight: CGFloat = 0.14
                                
                                let expandedWidth = min(
                                    originalBox.width + 0.04,
                                    maximumWidth
                                )
                                
                                let expandedHeight = min(
                                    originalBox.height + 0.04,
                                    maximumHeight
                                )
                                
                                var expandedBox = CGRect(
                                    x: originalBox.midX - expandedWidth / 2,
                                    y: originalBox.midY - expandedHeight / 2,
                                    width: expandedWidth,
                                    height: expandedHeight
                                )
                                
                                expandedBox = expandedBox.intersection(
                                    CGRect(x: 0, y: 0, width: 1, height: 1)
                                )
                                
                                if expandedBox.width > 0 &&
                                    expandedBox.height > 0 {
                                    
                                    currentObservation =
                                    VNDetectedObjectObservation(
                                        boundingBox: expandedBox
                                    )
                                    
                                } else {
                                    currentObservation = nil
                                }
                                
                            } else if self.phase == .armed {
                                currentObservation = result
                                
                            } else {
                                currentObservation = nil
                            }
                            lastCenter = center
                        }
                        
                    } else {
                        var isSavedByRescue = false
                        await MainActor.run {
                            if self.phase == .armed {
                                let startPt =
                                self.lockedBallCenter ?? initialPoint
                                
                                let dyFromStart =
                                startPt.y - lastCenter.y
                                
                                recentOriginColorDiffs.append(originColorDiff)
                                
                                if recentOriginColorDiffs.count > 5 {
                                    recentOriginColorDiffs.removeFirst()
                                }
                                
                                // Visionが対象を見失ったRescueフレームでも、
                                // 原点の色変化を連続回数へ反映する
                                if originColorDiff >= 0.010 {
                                    consecutiveOriginChangedFrames += 1
                                } else {
                                    consecutiveOriginChangedFrames = 0
                                }
                                
                                var stationaryFramesAtLastCenter = 0
                                
                                for pt in recentPoints.reversed() { if hypot(pt.x - lastCenter.x, pt.y - lastCenter.y) < 0.005 { stationaryFramesAtLastCenter += 1 } else { break } }
                                let distFromStart = hypot(lastCenter.x - startPt.x, startPt.y - lastCenter.y)
                                let isSuspiciousStationary = (distFromStart > 0.005) && (stationaryFramesAtLastCenter >= 5)
                                
                                let hasClearlyMovedUp =
                                dyFromStart >= 0.008
                                
                                let horizontalMoveIsSmall =
                                abs(lastCenter.x - startPt.x) < 0.06
                                
                                let originChangedContinuously =
                                consecutiveOriginChangedFrames >=
                                requiredOriginChangedFrames
                                
                                let movedUpContinuously =
                                consecutiveUpwardMoveFrames >=
                                requiredUpwardMoveFrames
                                
                                let hasUsableFlightPoint =
                                recentPoints.contains { point in
                                    let upwardDistance =
                                    startPt.y - point.y
                                    
                                    let horizontalDistance =
                                    abs(point.x - startPt.x)
                                    
                                    return upwardDistance >= 0.008 &&
                                    horizontalDistance <
                                        max(upwardDistance * 3.0, 0.03)
                                }
                                
                                if hasClearlyMovedUp &&
                                    horizontalMoveIsSmall &&
                                    originChangedContinuously &&
                                    movedUpContinuously &&
                                    hasUsableFlightPoint &&
                                    !isSuspiciousStationary {
                                    
                                    isSavedByRescue = true
                                    
                                    print(
                                        """
                                        🚨 SHOT ROUTE: imported-rescue
                                        time: \(relativeTime)
                                        originFrames: \(consecutiveOriginChangedFrames)
                                        upwardFrames: \(consecutiveUpwardMoveFrames)
                                        dyFromStart: \(dyFromStart)
                                        originDiff: \(originColorDiff)
                                        recentPointCount: \(recentPoints.count)
                                        lastCenterX: \(lastCenter.x)
                                        lastCenterY: \(lastCenter.y)
                                        """
                                    )

                                    self.phase = .shotTracking
                                    self.hintText =
                                    "ショット検知！弾道をシミュレーション中..."
                                    
                                    self.tracerPointsNormalized.removeAll()
                                    self.tracerPointsNormalized.append(startPt)
                                    
                                    let filterRate: CGFloat =
                                    self.selectedClub == "Toy/Indoor"
                                    ? 0.2
                                    : 0.3
                                    
                                    var lastRawPt = startPt
                                    
                                    for point in recentPoints {
                                        let dy =
                                        lastRawPt.y - point.y
                                        
                                        let dx =
                                        abs(point.x - lastRawPt.x)
                                        
                                        if dy > 0.002 &&
                                            point.y >= lastCenter.y &&
                                            dx < dy * 5.0 {
                                            
                                            self.tracerPointsNormalized.append(
                                                CGPoint(
                                                    x: startPt.x +
                                                    (point.x - startPt.x) *
                                                    filterRate,
                                                    y: point.y
                                                )
                                            )
                                            
                                            lastRawPt = point
                                        }
                                    }
                                    
                                    let finalDy =
                                    lastRawPt.y - lastCenter.y
                                    
                                    let finalDx =
                                    abs(lastCenter.x - lastRawPt.x)
                                    
                                    if finalDy > 0.002 &&
                                        finalDx < finalDy * 5.0 {
                                        
                                        self.tracerPointsNormalized.append(
                                            CGPoint(
                                                x: startPt.x +
                                                (lastCenter.x - startPt.x) *
                                                filterRate,
                                                y: lastCenter.y
                                            )
                                        )
                                    }
                                    
                                    self.videoShotTime =
                                    relativeTime - 0.05
                                }
                            }
                        }
                        if isSavedByRescue {
                            trackingFrameCount = 0
                            invalidTrackingFrames = 0
                            postImpactValidPointCount = 0
                            
                            // Visionが対象を見失った状態なので、
                            // 初期位置から追跡を再開せず予測へ移行する
                            shouldFinishPostImpactTracking = true
                            currentObservation = nil
                            
                        } else {
                            let phaseNow2 = await MainActor.run {
                                self.phase
                            }
                            
                            if phaseNow2 == .armed {
                                currentObservation =
                                    VNDetectedObjectObservation(
                                        boundingBox: visionBBox
                                    )

                                lastCenter = initialPoint
                                recentPoints.removeAll()
                                sequenceHandler =
                                    VNSequenceRequestHandler()

                                previousTrackerColor = nil
                                recentOriginColorDiffs.removeAll()

                                consecutiveOriginChangedFrames = 0
                                consecutiveUpwardMoveFrames = 0
                                consecutiveFrozenAwayFrames = 0
                                consecutiveImpactDisappearFrames = 0
                            } else if phaseNow2 == .shotTracking {
                                invalidTrackingFrames += 1
                                
                                print(
                                    "⚠️ ショット後にVision結果なし " +
                                    "\(invalidTrackingFrames)/\(maxInvalidTrackingFrames)"
                                )
                                
                                if invalidTrackingFrames >= maxInvalidTrackingFrames {
                                    shouldFinishPostImpactTracking = true
                                    currentObservation = nil
                                    
                                } else if currentObservation == nil {
                                    currentObservation = VNDetectedObjectObservation(
                                        boundingBox: visionBBox
                                    )
                                }
                                
                            } else {
                                currentObservation = nil
                            }
                        }
                    }
                    let phaseAfterProcessing = await MainActor.run {
                        self.phase
                    }
                    
                    if currentObservation == nil &&
                        phaseAfterProcessing == .shotTracking {
                        
                        break
                    }
                    
                    try? await Task.sleep(
                        nanoseconds: 5_000_000
                    )
                }
                
                print(
                    """
                    🏁 VIDEO LOOP ENDED
                    readerStatus: \(reader.status.rawValue)
                    readerError: \(String(describing: reader.error))
                    processedFrames: \(debugFrameCount)
                    currentObservationExists: \(currentObservation != nil)
                    shouldFinishPostImpactTracking: \(shouldFinishPostImpactTracking)
                    """
                )
                
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
            guard let self else {
                return
            }

            DispatchQueue.main.async {
                // インポート動画の追跡点はrunVideoAnalysisLoopで管理するため、
                // CameraManagerから届くライブカメラ用の追跡点は無視する
                guard !self.isVideoMode else {
                    print(
                        "⚠️ CameraManager.onTrackedPoint ignored in video mode"
                    )
                    return
                }

                // ライブカメラでショット追跡中の場合だけ点を追加する
                guard self.phase == .shotTracking else {
                    return
                }

                var filteredPoint = point

                if let startPt = self.lockedBallCenter {
                    let dx = point.x - startPt.x

                    let filterRate: CGFloat =
                        self.selectedClub == "Toy/Indoor"
                        ? 0.2
                        : 0.3

                    filteredPoint = CGPoint(
                        x: startPt.x + dx * filterRate,
                        y: point.y
                    )
                }

                // 最初の点としてボールのロック位置を追加する
                if self.tracerPointsNormalized.isEmpty,
                   let startPt = self.lockedBallCenter {

                    self.tracerPointsNormalized.append(
                        startPt
                    )
                }

                self.tracerPointsNormalized.append(
                    filteredPoint
                )

                self.camera.pointsToDraw =
                    self.tracerPointsNormalized
            }
        }
        camera.onShotBegan = { [weak self] in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                guard !self.isVideoMode else {
                    print(
                        "⚠️ CameraManager.onShotBegan ignored in video mode"
                    )
                    return
                }

                print(
                    "🚨 SHOT ROUTE: CameraManager.onShotBegan"
                )

                self.phase = .shotTracking
                self.hintText =
                    "ショット検知！弾道をシミュレーション中..."
            }
        }
        
        camera.onShotEnded = { [weak self] in
            guard let self else {
                return
            }

            DispatchQueue.main.async {
                guard !self.isVideoMode else {
                    print(
                        "⚠️ CameraManager.onShotEnded ignored in video mode"
                    )
                    return
                }

                self.runBallisticSimulation()
                self.phase = .idle
                self.hintText =
                    "計測完了！動画を合成保存します..."

                self.camera.stopRecordingWithMetrics(
                    carry: self.metrics.carryYards,
                    speed: self.metrics.ballSpeedMS,
                    launch: self.metrics.launchDeg,
                    apex: self.metrics.apexFeet
                )
            }
        }
        
        camera.onTrackingLost = { [weak self] in
            guard let self else {
                return
            }

            DispatchQueue.main.async {
                // インポート動画の追跡はrunVideoAnalysisLoopで管理するため、
                // CameraManagerからの追跡喪失通知は無視する
                guard !self.isVideoMode else {
                    print(
                        "⚠️ CameraManager.onTrackingLost ignored in video mode"
                    )
                    return
                }

                // ここから下はライブカメラ専用
                if self.phase == .shotTracking {
                    self.runBallisticSimulation()
                    self.phase = .idle
                    self.hintText =
                        "計測完了（途切れ）：先を予測保存します"

                    self.camera.stopRecordingWithMetrics(
                        carry: self.metrics.carryYards,
                        speed: self.metrics.ballSpeedMS,
                        launch: self.metrics.launchDeg,
                        apex: self.metrics.apexFeet
                    )

                } else if self.phase == .searching {
                    self.phase = .idle
                    self.hintText =
                        "ボールを見失いました"
                    self.debugBoundingBoxNormalized = nil
                }
            }
        }
    }

            private func runBallisticSimulation() {
                guard let startPt =
                        lockedBallCenter ??
                        tracerPointsNormalized.first else {
                    return
                }

                let rawPoints = tracerPointsNormalized

                // startPt以外に最低1点あれば予測できるようにする
                guard rawPoints.count >= 2 else {
                    tracerPointsNormalized = [
                        startPt,
                        CGPoint(
                            x: startPt.x,
                            y: startPt.y - 0.02
                        )
                    ]

                    metrics.ballSpeedMS = 0
                    metrics.launchDeg = 0
                    metrics.carryYards = 0
                    metrics.apexFeet = 0
                    return
                }

                // 有効な実測点だけを抽出する
                var measuredPoints: [CGPoint] = []

                for point in rawPoints {
                    let clampedPoint = CGPoint(
                        x: min(max(point.x, 0.0), 1.0),
                        y: min(max(point.y, 0.0), 1.0)
                    )

                    if let last = measuredPoints.last {
                        let distance = hypot(
                            clampedPoint.x - last.x,
                            clampedPoint.y - last.y
                        )

                        if distance >= 0.0015 &&
                            distance <= 0.12 {

                            measuredPoints.append(clampedPoint)
                        }
                    } else {
                        measuredPoints.append(clampedPoint)
                    }
                }

                guard measuredPoints.count >= 2 else {
                    return
                }

                // 実測点の先頭と末尾から平均速度ベクトルを求める。
                // 実測点は原則60fpsとして扱う。
                let firstMeasuredPoint = measuredPoints.first!
                let lastMeasuredPoint = measuredPoints.last!

                let measuredIntervals =
                    max(1, measuredPoints.count - 1)

                let measuredTime =
                    CGFloat(measuredIntervals) / 60.0

                var velocityX =
                    (lastMeasuredPoint.x - firstMeasuredPoint.x) /
                    measuredTime

                var velocityY =
                    (firstMeasuredPoint.y - lastMeasuredPoint.y) /
                    measuredTime

                // 異常なVisionジャンプを抑制する
                velocityX = max(
                    -1.2,
                    min(1.2, velocityX)
                )

                velocityY = max(
                    0.10,
                    min(2.2, velocityY)
                )

                let screenSpeed = hypot(
                    Double(velocityX),
                    Double(velocityY)
                )

                let launchAngleRadians = atan2(
                    Double(velocityY),
                    max(abs(Double(velocityX)), 0.01)
                )

                let launchAngleDegrees =
                    launchAngleRadians * 180.0 / .pi

                metrics.ballSpeedMS = max(
                    20.0,
                    min(80.0, 20.0 + screenSpeed * 25.0)
                )

                metrics.launchDeg = max(
                    8.0,
                    min(35.0, launchAngleDegrees)
                )

                // 表示用の予測トレーサー
                var predictedPoints = measuredPoints

                // 選択中のクラブに対応する弾道設定
                let profile = trajectoryProfile(
                    for: selectedClub
                )

                let predictionStep: CGFloat = 1.0 / 60.0

                let laserDuration =
                    profile.laserDuration

                let climbDuration =
                    profile.climbDuration

                var maximumRise: CGFloat = 0
                var predictionTime: CGFloat = 0

                // --------------------------------------------------
                // レーザー区間の終了位置
                // --------------------------------------------------

                let laserEndX =
                    lastMeasuredPoint.x +
                    velocityX *
                    laserDuration *
                    profile.horizontalScale

                let laserEndY =
                    lastMeasuredPoint.y -
                    velocityY *
                    laserDuration *
                    profile.laserVerticalScale

                // --------------------------------------------------
                // クラブ別の頂点位置
                // --------------------------------------------------

                let additionalRise = min(
                    profile.maximumAdditionalRise,
                    max(
                        profile.minimumAdditionalRise,
                        velocityY *
                        profile.additionalRiseScale
                    )
                )

                let apexY =
                    laserEndY -
                    additionalRise

                let apexX =
                    laserEndX +
                    velocityX *
                    climbDuration *
                    profile.horizontalScale *
                    profile.climbHorizontalRate

                // --------------------------------------------------
                // 3段階の予測軌道
                // --------------------------------------------------

                for _ in 1...240 {
                    predictionTime += predictionStep

                    let predictedPoint: CGPoint

                    if predictionTime <= laserDuration {
                        // ==========================================
                        // 1. インパクト直後のレーザー区間
                        // ==========================================

                        let progress =
                            predictionTime / laserDuration

                        predictedPoint = CGPoint(
                            x: lastMeasuredPoint.x +
                                (laserEndX - lastMeasuredPoint.x) *
                                progress,

                            y: lastMeasuredPoint.y +
                                (laserEndY - lastMeasuredPoint.y) *
                                progress
                        )

                    } else if predictionTime <=
                                laserDuration + climbDuration {

                        // ==========================================
                        // 2. レーザー終了点から頂点への移行
                        // ==========================================

                        let climbTime =
                            predictionTime -
                            laserDuration

                        let progress = min(
                            1.0,
                            climbTime / climbDuration
                        )

                        // 頂点に近づくほど上昇速度を弱める
                        let easedProgress =
                            1.0 -
                            pow(
                                1.0 - progress,
                                2.4
                            )

                        predictedPoint = CGPoint(
                            x: laserEndX +
                                (apexX - laserEndX) *
                                progress,

                            y: laserEndY +
                                (apexY - laserEndY) *
                                easedProgress
                        )

                    } else {
                        // ==========================================
                        // 3. 頂点からの落下区間
                        // ==========================================

                        let fallTime =
                            predictionTime -
                            laserDuration -
                            climbDuration

                        let horizontalFallSpeed =
                            velocityX *
                            profile.horizontalScale *
                            profile.fallHorizontalRate

                        predictedPoint = CGPoint(
                            x: apexX +
                                horizontalFallSpeed *
                                fallTime,

                            y: apexY +
                                profile.fallGravity *
                                fallTime *
                                fallTime
                        )
                    }

                    // 左右へ大きく画面外に出た場合
                    if predictedPoint.x < -0.10 ||
                        predictedPoint.x > 1.10 {

                        break
                    }

                    // 上方向へ大きく画面外に出た場合
                    if predictedPoint.y < -0.15 {
                        break
                    }

                    // 頂点を過ぎて地面付近へ戻った場合
                    if predictedPoint.y >=
                        min(
                            0.95,
                            startPt.y + 0.03
                        ) &&
                        predictionTime >
                        laserDuration + climbDuration {

                        break
                    }

                    predictedPoints.append(
                        predictedPoint
                    )

                    maximumRise = max(
                        maximumRise,
                        startPt.y - predictedPoint.y
                    )
                }


                metrics.carryYards = max(
                    5.0,
                    min(
                        320.0,
                        metrics.ballSpeedMS *
                        cos(launchAngleRadians) *
                        4.2
                    )
                )

                metrics.apexFeet = max(
                    1.0,
                    min(
                        180.0,
                        Double(maximumRise) * 280.0
                    )
                )

                simulatedHangTime = min(
                    6.0,
                    max(1.0, Double(predictionTime))
                )

                tracerPointsNormalized = predictedPoints
                camera.pointsToDraw = predictedPoints
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
