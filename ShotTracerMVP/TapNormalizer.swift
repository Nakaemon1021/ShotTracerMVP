//
//  TapNormalizer.swift
//  ShotTracerMVP
//
//  Created by 中江 宏仁 on 2026/02/07.
//

import SwiftUI

struct TapNormalizer: View {
    let isEnabled: Bool
    var onTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            guard isEnabled else { return }
                            let p = value.location
                            let normalized = CGPoint(
                                x: p.x / max(1, geo.size.width),
                                y: p.y / max(1, geo.size.height)
                            )
                            onTap(normalized)
                        }
                )
        }
    }
}
