import SwiftUI
import PhotosUI
import AVFoundation

struct MeasurementScreen: View {
    @StateObject private var vm = MeasurementViewModel()
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea() // 全体の背景（ピラーボックスの余白）を黒に
            
            // 映像とグラフィック領域のみを16:9に固定
            ZStack {
                // 1. 映像レイヤー
                CameraPreviewView(session: vm.camera.session) { layer in
                    vm.camera.setPreviewLayer(layer)
                }
                .onAppear {
                    vm.camera.start()
                    vm.selectedClub = "Driver" // デフォルト
                }
                .onDisappear {
                    vm.camera.stop()
                }
                
                // 動画モードの時は、サムネイル画像をカメラ映像の「上」に重ねて表示する
                if let thumbnail = vm.videoThumbnail {
                    GeometryReader { geo in
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geo.size.width,
                                height: geo.size.height
                            )
                            .clipped()
                    }
                }
                
                // 2. タップ領域レイヤー
                GeometryReader { geo in
                    Color.white.opacity(0.001) // 確実にタップを拾うため透過色を指定
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if vm.phase == .armed || vm.phase == .shotTracking {
                                vm.forceEndAndSave()

                            } else if vm.isTapEnabled {

                                // 動画モードでは、armTrackingより先に正規化座標を設定する
                                if let thumbnail = vm.videoThumbnail {
                                    vm.aimPointNormalized = normalizedPointForAspectFillTap(
                                        location: location,
                                        containerSize: geo.size,
                                        imageSize: thumbnail.size
                                    )
                                }

                                vm.armTracking(atPixelPoint: location)
                            }
                        }
                }
                
                // 3. グラフィック＆オーバーレイレイヤー
                GeometryReader { geo in
                    let screenW = geo.size.width
                    let screenH = geo.size.height
                    
                    if vm.phase == .searching {
                        TargetGuideOverlay()
                    }
                    
                    // ★ 修正: リセット時に青枠が消えるように、phaseが .armed の時だけ表示するように厳格化
                    if vm.phase == .armed {
                        if let thumbnail = vm.videoThumbnail {
                            if let aim = vm.aimPointNormalized {
                                let displayPoint =
                                    displayPointForAspectFillNormalizedPoint(
                                        normalizedPoint: aim,
                                        containerSize: geo.size,
                                        imageSize: thumbnail.size
                                    )

                                FocusCircleView(
                                    position: displayPoint,
                                    size: 0.045 * screenW
                                )
                            }
                        } else {
                            DebugBoundingBoxOverlay(
                                boxNormalized: vm.debugBoundingBoxNormalized
                            )
                        }
                    }
                    
                    // リアルタイム弾道トレーサー
                    TracerOverlayGlow(
                        pointsNormalized: vm.tracerPointsNormalized,
                        color: Color(red: 1.0, green: 0.0, blue: 0.35),
                        opacity: vm.tracerOpacity,
                        width: vm.tracerWidth,
                        glowWidth: vm.tracerGlowWidth,
                        glowOpacity: vm.tracerGlowOpacity,
                        glowBlur: vm.tracerGlowBlur
                    )
                    
                    // リアルタイムPGAツアーステータステロップ
                    if vm.metrics.carryYards > 0 && vm.tracerPointsNormalized.count > 1 {
                        let layout = calculateLayout(points: vm.tracerPointsNormalized, width: screenW, height: screenH)
                        
                        PopupBubbleView(
                            text: String(format: "BALL SPEED %.1f m/s  /  LAUNCH %.1f°", vm.metrics.ballSpeedMS, vm.metrics.launchDeg),
                            gradientColors: [Color(red: 0.10, green: 0.25, blue: 0.45), Color(red: 0.05, green: 0.12, blue: 0.25)],
                            arrowDirection: .left
                        )
                        .position(x: layout.startX + 145, y: layout.startY - 30)
                        
                        PopupBubbleView(
                            text: String(format: "APEX  %.0f ft", vm.metrics.apexFeet),
                            gradientColors: [Color(red: 0.16, green: 0.38, blue: 0.64), Color(red: 0.08, green: 0.20, blue: 0.38)],
                            arrowDirection: layout.isTooClose ? .bottomRight : .right
                        )
                        .position(
                            x: layout.isTooClose ? (layout.apexX - 60) : (layout.apexX - 50),
                            y: layout.isTooClose ? (layout.apexY - 50) : (layout.apexY - 30)
                        )
                        
                        PopupBubbleView(
                            text: String(format: "CARRY %.0f yds", vm.metrics.carryYards),
                            gradientColors: [Color(red: 0.12, green: 0.42, blue: 0.22), Color(red: 0.05, green: 0.22, blue: 0.10)],
                            arrowDirection: layout.isTooClose ? .left : .bottom
                        )
                        .position(
                            x: layout.isTooClose ? (layout.carryX + 60) : layout.carryX,
                            y: layout.isTooClose ? layout.carryY : (layout.carryY - 45)
                        )
                    }
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()
            
            
            // ----------------------------------------------------
            // 4. UIコントロール層
            // ----------------------------------------------------
            
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Text(vm.hintText)
                        .font(.subheadline)
                        .bold()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .foregroundStyle(Color.white)
                        .clipShape(Capsule())
                    Spacer()
                }
                
                if vm.isRecording && vm.videoThumbnail == nil {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                        Text("REC")
                            .font(.headline)
                            .bold()
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.top, 20)
            
            VStack {
                HStack {
                    Menu {
                        ForEach(["Driver", "3W", "5W", "7I", "9I", "PW", "SW", "Toy/Indoor"], id: \.self) { club in
                            Button(club) {
                                vm.selectedClub = club
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "golfshot")
                            Text(vm.selectedClub).bold()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        zoomButton("1x", scale: 1.0)
                        zoomButton("2x", scale: 2.0)
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                }
                .padding(.top, 20)
                .padding(.horizontal, 16)
                Spacer()
            }
            
            VStack {
                Spacer()
                HStack {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        VStack(spacing: 4) {
                            Image(systemName: "video.badge.plus")
                                .font(.title3)
                            Text("IMPORT")
                                .font(.system(size: 8, weight: .black))
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                    }
                    Spacer()
                }
                .padding(.leading, 24)
                .padding(.bottom, 55) // ★ 少し下げて押しやすく調整
            }
            .onChange(of: selectedItem) {
                guard let item = selectedItem else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                        try? data.write(to: tempURL)
                        await MainActor.run {
                            vm.prepareVideoAnalysis(at: tempURL)
                        }
                    }
                }
            }
            
            VStack {
                Spacer()
                BottomControlBar(vm: vm)
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
    }
    
    private struct LayoutData {
        let startX: CGFloat
        let startY: CGFloat
        let apexX: CGFloat
        let apexY: CGFloat
        let carryX: CGFloat
        let carryY: CGFloat
        let isTooClose: Bool
    }
    
    private func calculateLayout(points: [CGPoint], width: CGFloat, height: CGFloat) -> LayoutData {
        guard let firstPt = points.first, let lastPt = points.last else {
            return LayoutData(startX: 0, startY: 0, apexX: 0, apexY: 0, carryX: 0, carryY: 0, isTooClose: false)
        }
        
        var apexIdx = 0
        var minY = firstPt.y
        for (i, p) in points.enumerated() {
            if p.y < minY {
                minY = p.y
                apexIdx = i
            }
        }
        
        let apexPt = points[apexIdx]
        let startX = firstPt.x * width
        let startY = firstPt.y * height
        let apexX = apexPt.x * width
        let apexY = apexPt.y * height
        let carryX = lastPt.x * width
        let carryY = lastPt.y * height
        let isTooClose = hypot(apexX - carryX, apexY - carryY) < (width * 0.15)
        
        return LayoutData(
            startX: startX,
            startY: startY,
            apexX: apexX,
            apexY: apexY,
            carryX: carryX,
            carryY: carryY,
            isTooClose: isTooClose
        )
    }
    
    private func normalizedPointForAspectFillTap(
        location: CGPoint,
        containerSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        guard containerSize.width > 0,
              containerSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let scale = max(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )

        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale

        let cropX = max(
            0,
            (displayedWidth - containerSize.width) / 2.0
        )

        let cropY = max(
            0,
            (displayedHeight - containerSize.height) / 2.0
        )

        let imageX = (location.x + cropX) / scale
        let imageY = (location.y + cropY) / scale

        let normalizedX = min(
            max(imageX / imageSize.width, 0.0),
            1.0
        )

        let normalizedY = min(
            max(imageY / imageSize.height, 0.0),
            1.0
        )

        return CGPoint(
            x: normalizedX,
            y: normalizedY
        )
    }
    
    @ViewBuilder
    private func zoomButton(_ title: String, scale: CGFloat) -> some View {
        Button(action: { vm.setZoom(scale: scale) }) {
            Text(title)
                .font(.caption)
                .bold()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(vm.currentZoomScale == scale ? Color.blue : Color.clear)
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
        }
    }
    
    private func displayPointForAspectFillNormalizedPoint(
        normalizedPoint: CGPoint,
        containerSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        guard containerSize.width > 0,
              containerSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGPoint(
                x: containerSize.width / 2,
                y: containerSize.height / 2
            )
        }

        let scale = max(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )

        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale

        let cropX = max(
            0,
            (displayedWidth - containerSize.width) / 2
        )

        let cropY = max(
            0,
            (displayedHeight - containerSize.height) / 2
        )

        return CGPoint(
            x: normalizedPoint.x * displayedWidth - cropX,
            y: normalizedPoint.y * displayedHeight - cropY
        )
    }
    
}

// ★ 追加：キュッとフォーカスされるアニメーションを持つロックオン枠
struct FocusCircleView: View {
    let position: CGPoint
    let size: CGFloat
    
    @State private var scale: CGFloat = 1.8
    @State private var opacity: Double = 0.0
    
    var body: some View {
        Circle()
            // 視認性の良い明るめの青にし、少しだけ太くする
            .stroke(Color(red: 0.05, green: 0.4, blue: 0.9), lineWidth: 2.5)
            // ほんのり光るグロー効果を追加してハイテク感を演出
            .shadow(color: Color.blue.opacity(0.5), radius: 4, x: 0, y: 0)
            .frame(width: size, height: size)
            .position(x: position.x, y: position.y)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                // スプリングアニメーションでキュッと吸い付く動き
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5, blendDuration: 0)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
    }
}

struct PopupBubbleView: View {
    let text: String
    let gradientColors: [Color]
    let arrowDirection: ArrowDirection
    
    enum ArrowDirection { case left, right, bottom, bottomRight }
    
    var body: some View {
        HStack(spacing: 0) {
            if arrowDirection == .left {
                TriangleShape()
                    .fill(gradientColors.first!)
                    .frame(width: 10, height: 7)
                    .rotationEffect(.degrees(-90))
                    .offset(x: 4)
            }
            
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                
            if arrowDirection == .right {
                TriangleShape()
                    .fill(gradientColors.first!)
                    .frame(width: 10, height: 7)
                    .rotationEffect(.degrees(90))
                    .offset(x: -4)
            }
        }
        .fixedSize()
        .overlay(alignment: .bottom) {
            if arrowDirection == .bottom {
                TriangleShape()
                    .fill(gradientColors.first!)
                    .frame(width: 10, height: 7)
                    .rotationEffect(.degrees(180))
                    .offset(y: 8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if arrowDirection == .bottomRight {
                TriangleShape()
                    .fill(gradientColors.first!)
                    .frame(width: 10, height: 7)
                    .rotationEffect(.degrees(135))
                    .offset(x: 5, y: 5)
            }
        }
    }
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct TargetGuideOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.12
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .frame(width: w, height: w)
                
                Circle()
                    .fill(Color.yellow.opacity(0.8))
                    .frame(width: 4, height: 4)

                Text("PLACE BALL")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.yellow)
                    .offset(y: w/2 + 18)
            }
            // ★ 修正: Auto Modeの枠を少し上(0.72 -> 0.65)にずらし、マット端の誤検知を防ぎます
            .position(x: geo.size.width * 0.5, y: geo.size.height * 0.65)
        }
    }
}

struct DebugBoundingBoxOverlay: View {
    let boxNormalized: CGRect?
    
    var body: some View {
        if let rect = boxNormalized {
            GeometryReader { geo in
                Circle()
                    .stroke(Color(red: 0.05, green: 0.1, blue: 0.55), lineWidth: 2.0)
                    .frame(width: rect.size.width * geo.size.width, height: rect.size.height * geo.size.height)
                    .position(x: rect.midX * geo.size.width, y: rect.midY * geo.size.height)
            }
        }
    }
}

struct BottomControlBar: View {
    @ObservedObject var vm: MeasurementViewModel

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(vm.phase.rawValue)
                    .bold()
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.15))
            .clipShape(Capsule())

            Spacer()

            Button(action: {
                vm.startAutoMode()
            }) {
                Label("Auto Mode", systemImage: "bolt.fill")
                    .font(.footnote)
                    .bold()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("Reset") {
                vm.resetTracer()
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var statusColor: Color {
        switch vm.phase {
        case .idle:
            return .gray

        case .searching:
            return .blue

        case .armed:
            return .green

        case .shotTracking:
            return .red
        }
    }
}
