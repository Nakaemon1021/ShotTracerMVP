//
//  TracerOverlayGlow.swift
//  ShotTracerMVP
//
//  Created by 中江 宏仁 on 2026/02/07.
//

import SwiftUI

struct TracerOverlayGlow: View {
    let pointsNormalized: [CGPoint]
    let color: Color
    let opacity: Double
    let width: Double

    let glowWidth: Double
    let glowOpacity: Double
    let glowBlur: Double

    // 先端ハイライト
    let highlightSegments: Int = 5
    let highlightOpacity: Double = 0.95
    let highlightWidthMultiplier: Double = 1.25
    let headDotSize: CGFloat = 10

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                guard pointsNormalized.count >= 2 else { return }

                // 正規化(0..1) → 実座標
                let pts = pointsNormalized.map {
                    CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                }

                // 全体パス
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }

                // ✅ グローは drawLayer に閉じ込める（blurが本線に影響しない）
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: glowBlur))
                    layer.stroke(
                        path,
                        with: .color(color.opacity(glowOpacity)),
                        style: StrokeStyle(lineWidth: glowWidth, lineCap: .round, lineJoin: .round)
                    )
                }

                // 本線
                context.stroke(
                    path,
                    with: .color(color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )

                // 先端ハイライト（最後の数セグメントだけ重ね描き）
                let n = pts.count
                let startIndex = max(0, n - 1 - highlightSegments)

                if startIndex < n - 1 {
                    for i in startIndex..<(n - 1) {
                        var seg = Path()
                        seg.move(to: pts[i])
                        seg.addLine(to: pts[i + 1])

                        // 先端に近いほど明るく
                        let t = Double(i - startIndex + 1) / Double(max(1, (n - 1) - startIndex))
                        let segOpacity = (opacity * 0.6) + t * (highlightOpacity - (opacity * 0.6))

                        context.stroke(
                            seg,
                            with: .color(color.opacity(segOpacity)),
                            style: StrokeStyle(
                                lineWidth: width * highlightWidthMultiplier,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }

                    // 先端ドット（ヘッド）
                    if let last = pts.last {
                        // ドットの薄いグロー
                        context.drawLayer { layer in
                            layer.addFilter(.blur(radius: 8))
                            layer.fill(
                                Path(ellipseIn: CGRect(
                                    x: last.x - headDotSize,
                                    y: last.y - headDotSize,
                                    width: headDotSize * 2,
                                    height: headDotSize * 2
                                )),
                                with: .color(color.opacity(0.25))
                            )
                        }

                        // ドット本体
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: last.x - headDotSize/2,
                                y: last.y - headDotSize/2,
                                width: headDotSize,
                                height: headDotSize
                            )),
                            with: .color(color.opacity(0.95))
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
