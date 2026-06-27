//
//  AimRingOverlay.swift
//  ShotTracerMVP
//
//  Created by 中江 宏仁 on 2026/02/07.
//

import SwiftUI

struct AimRingOverlay: View {
    let aimPointNormalized: CGPoint?
    let isVisible: Bool

    @State private var pulse = false
    @State private var appear = false

    var body: some View {
        GeometryReader { geo in
            if let p = aimPointNormalized, isVisible {
                let x = p.x * geo.size.width
                let y = p.y * geo.size.height

                AimRingView(pulse: pulse)
                    .position(x: x, y: y)
                    .opacity(appear ? 1 : 0)
                    .onAppear {
                        appear = true
                        startPulse()
                    }
                    .onChange(of: aimPointNormalized) { _, _ in
                        startPulse()
                    }
                    .onDisappear {
                        appear = false
                        pulse = false
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private func startPulse() {
        pulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.easeOut(duration: 0.18)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeInOut(duration: 0.22)) { pulse = false }
            }
        }
    }
}

struct AimRingView: View {
    let pulse: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.yellow.opacity(0.25), lineWidth: 10)
                .blur(radius: 8)
                .frame(width: 70, height: 70)
                .scaleEffect(pulse ? 1.12 : 1.0)
                .opacity(pulse ? 0.9 : 0.7)

            Circle()
                .stroke(Color.yellow.opacity(0.9), lineWidth: 3)
                .frame(width: 62, height: 62)
                .scaleEffect(pulse ? 1.06 : 1.0)

            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: 44, height: 44)

            Circle()
                .fill(Color.yellow.opacity(0.95))
                .frame(width: 6, height: 6)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }
}
