// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// A horizontal scroll is only provenance, not proof of a history swipe.
/// Feedback additionally requires an allowed main-frame back/forward navigation
/// and its commit. WebKit still owns gesture recognition and navigation.
struct HistoryGestureProvenance {
    enum Phase { case began, changed, ended, cancelled }

    private static let maximumAge: TimeInterval = 1
    private var lastSample: TimeInterval?
    private var travel = CGSize.zero
    private var vertical = false
    private var pendingNavigation = false

    mutating func update(x: CGFloat, y: CGFloat, phase: Phase, precise: Bool,
                         canNavigate: Bool, timestamp: TimeInterval) {
        if phase == .began { reset() }
        guard precise, canNavigate, timestamp.isFinite, x.isFinite, y.isFinite,
              phase != .cancelled else { reset(); return }
        if phase == .began { lastSample = timestamp }
        // A policy decision can arrive before the final wheel event. Do not
        // clear its pending confirmation just because provenance was consumed.
        guard let previous = lastSample else { return }
        guard timestamp >= previous else { reset(); return }
        lastSample = timestamp
        guard phase != .ended, !vertical else { return }
        travel.width += x
        travel.height += y
        guard travel.width.isFinite, travel.height.isFinite else { reset(); return }
        let horizontalDistance = abs(travel.width), verticalDistance = abs(travel.height)
        if verticalDistance >= 8, verticalDistance > horizontalDistance * 1.3 {
            vertical = true
        }
    }

    mutating func discreteSwipe(x: CGFloat, y: CGFloat, canNavigate: Bool, timestamp: TimeInterval) {
        reset()
        guard canNavigate, timestamp.isFinite, x.isFinite, y.isFinite,
              abs(x) > abs(y), x != 0 else { return }
        lastSample = timestamp
        travel = CGSize(width: x, height: y)
    }

    mutating func navigationAllowed(isBackForward: Bool, at timestamp: TimeInterval) {
        let age = lastSample.map { timestamp - $0 }
        let horizontal = !vertical && abs(travel.width) > abs(travel.height) * 1.3
        reset()
        pendingNavigation = isBackForward && horizontal && timestamp.isFinite &&
            age.map { $0 >= 0 && $0 <= Self.maximumAge } == true
    }

    mutating func navigationCommitted() -> Bool {
        let confirmed = pendingNavigation
        reset()
        return confirmed
    }

    mutating func reset() {
        lastSample = nil
        travel = .zero
        vertical = false
        pendingNavigation = false
    }
}
