//
//  Models.swift
//  ShotTracerMVP
//
//  Created by 中江 宏仁 on 2026/02/07.
//

import SwiftUI
import CoreGraphics

enum TrackPhase: String {
    case idle = "Idle"
    case armed = "Armed"
    case shotTracking = "Tracking"
}

struct ShotMetrics {
    var carryYards: Double = 0
    var launchDeg: Double = 0
    var directionDeg: Double = 0   // +右 / -左
    var ballSpeedMS: Double = 0
}

// 逐次型EMA（指数移動平均）フィルタ
struct OnlineEMAFilter {
    var alpha: CGFloat
    private(set) var hasState: Bool
    private var state: CGPoint

    init(alpha: CGFloat = 0.35) {
        self.alpha = alpha
        self.hasState = false
        self.state = .zero
    }

    mutating func reset() {
        hasState = false
        state = .zero
    }

    mutating func update(_ p: CGPoint) -> CGPoint {
        if !hasState {
            state = p
            hasState = true
            return p
        }
        state.x = state.x + alpha * (p.x - state.x)
        state.y = state.y + alpha * (p.y - state.y)
        return state
    }
}

// 距離ベース間引き
struct DistanceThinner {
    var minDistance: CGFloat
    private(set) var hasLast: Bool
    private var last: CGPoint

    init(minDistance: CGFloat = 0.008) {
        self.minDistance = minDistance
        self.hasLast = false
        self.last = .zero
    }

    mutating func reset() {
        hasLast = false
        last = .zero
    }

    mutating func push(_ p: CGPoint) -> CGPoint? {
        if !hasLast {
            last = p
            hasLast = true
            return p
        }
        let dx = p.x - last.x
        let dy = p.y - last.y
        if (dx*dx + dy*dy) >= (minDistance * minDistance) {
            last = p
            return p
        }
        return nil
    }
}
