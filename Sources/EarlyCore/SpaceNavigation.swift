// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Shared bounds for footer, keyboard and swipe navigation. Selection never wraps.
public enum SpaceNavigation {
    public static func targetIndex(current: Int, count: Int, delta: Int) -> Int? {
        guard count > 0, (0..<count).contains(current), delta == -1 || delta == 1 else { return nil }
        let next = current + delta
        return (0..<count).contains(next) ? next : nil
    }

    public static func shortcutIndex(number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        let index = number == 9 ? count - 1 : number - 1
        return index < count ? index : nil
    }

    /// Fraction of one sidebar page. Interior pages track the fingers directly;
    /// the first/last boundary resists travel instead of exposing a blank page.
    public static func sidebarTravel(translation: Double, width: Double, canGoPrevious: Bool, canGoNext: Bool) -> Double {
        guard translation.isFinite, width.isFinite, width > 0 else { return 0 }
        let hasNeighbor = translation > 0 ? canGoPrevious : canGoNext
        if hasNeighbor { return min(1, max(-1, translation / width)) }
        let limit = min(52, width * 0.24)
        guard limit > 0 else { return 0 }
        let resisted = limit * (1 - 1 / (1 + abs(translation) / limit))
        return (translation < 0 ? -resisted : resisted) / width
    }

    /// Keep the active page and its immediate neighbors mounted in one stable
    /// identity domain, including before and after a swipe commits.
    public static func sidebarPageRange(current: Int, count: Int) -> Range<Int> {
        guard count > 0, (0..<count).contains(current) else { return 0..<0 }
        return max(0, current - 1)..<(current < count - 1 ? current + 2 : count)
    }

    /// Page-width units. At commit, the incoming page stays at zero and the
    /// outgoing page stays offscreen, without a reset/rebuild frame between.
    public static func sidebarPagePosition(index: Int, current: Int, progress: Double) -> Double {
        Double(index) - Double(current) + progress
    }

    /// Filled at the center, outlined one page away. This continuously follows
    /// the swipe and has the same value immediately before/after selection.
    public static func indicatorFill(index: Int, current: Int, count: Int, progress: Double) -> Double {
        guard (0..<max(0, count)).contains(index), (0..<max(0, count)).contains(current) else { return 0 }
        let position = min(Double(count - 1), max(0, Double(current) - (progress.isFinite ? progress : 0)))
        return max(0, 1 - abs(Double(index) - position))
    }

    /// Reserve both side controls and, when needed, one overflow control. Keep
    /// the active dot in a bounded centered cluster even with many Spaces.
    public static func footerRange(count: Int, activeIndex: Int, width: Double) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let safeWidth = width.isFinite ? min(max(width, 0), 1000) : 240
        let capacity = min(5, max(2, Int((safeWidth - 80) / 26)))
        let visible = min(count, count > capacity ? capacity - 1 : capacity)
        let active = min(max(activeIndex, 0), count - 1)
        let start = min(max(0, active - visible / 2), count - visible)
        return start..<(start + visible)
    }
}

/// Trackpad samples are cumulative within one physical gesture. The AppKit
/// adapter supplies phases and excludes wheel/momentum input and other regions.
public struct SpaceSwipe: Sendable {
    public enum Phase: Sendable { case began, changed, ended, cancelled }
    public enum Action: Equatable, Sendable { case previous, next, create }
    public struct Update: Equatable, Sendable {
        public var consumed = false
        public var action: Action?
        public var creationProgress = 0.0
        public var crossedThreshold = false
        public var translation = 0.0
    }
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var active = false
    private var x = 0.0
    private var y = 0.0
    private var signaledThreshold = false
    public static let switchDistance = 72.0
    public static let createDistance = 180.0

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func update(x dx: Double, y dy: Double, phase: Phase,
                                canGoPrevious: Bool, canGoNext: Bool) -> Update {
        if case .began = phase { reset(); active = true }
        guard active else { return Update() }
        guard dx.isFinite, dy.isFinite else { reset(); return Update() }
        if case .cancelled = phase {
            let consumed = axis == .horizontal
            reset()
            return Update(consumed: consumed)
        }
        x += dx
        y += dy
        if axis == .undecided, max(abs(x), abs(y)) >= 12 {
            if abs(x) > abs(y) * 1.5 { axis = .horizontal }
            else if abs(y) > abs(x) * 1.5 { axis = .vertical }
        }
        var result = Update(consumed: axis == .horizontal)
        if axis == .horizontal {
            result.translation = x
            let horizontal = abs(x) > abs(y) * 1.2
            if x < 0, !canGoNext { result.creationProgress = min(1, max(0, -x / Self.createDistance)) }
            let candidate: Action? = horizontal ? (
                x >= Self.switchDistance && canGoPrevious ? .previous :
                x <= -Self.switchDistance && canGoNext ? .next :
                x <= -Self.createDistance && !canGoNext ? .create : nil
            ) : nil
            if candidate != nil, !signaledThreshold {
                result.crossedThreshold = true
                signaledThreshold = true
            }
            if case .ended = phase { result.action = candidate }
        }
        if case .ended = phase { reset() }
        return result
    }
}
