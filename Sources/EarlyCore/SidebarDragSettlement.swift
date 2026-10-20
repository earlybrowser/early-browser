// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// The released drag stays visible until fresh destination geometry is known.
/// Preview offsets and durable placement are exchanged without animation; only
/// this proxy travels to the final row/tile, never from the item's old section.
public struct SidebarDragSettlement: Equatable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public private(set) var frame: CGRect
    public private(set) var opacity: Double = 1
    public private(set) var animationID: UUID?
    public private(set) var isComplete = false

    public init?(itemID: UUID, releasedFrame: CGRect) {
        guard Self.isUsable(releasedFrame) else { return nil }
        id = UUID()
        self.itemID = itemID
        frame = releasedFrame
    }

    /// A changing viewport/section height can retarget the same landing. Old
    /// geometry and superseded animation completions must never reveal it early.
    public mutating func retarget(to frame: CGRect, visible: Bool, layoutID: UUID) -> UUID? {
        guard layoutID == id, !isComplete, Self.isUsable(frame),
              animationID == nil || self.frame != frame || opacity != (visible ? 1 : 0) else { return nil }
        self.frame = frame
        opacity = visible ? 1 : 0
        let next = UUID()
        animationID = next
        return next
    }

    @discardableResult public mutating func complete(animationID: UUID) -> Bool {
        guard self.animationID == animationID, !isComplete else { return false }
        isComplete = true
        return true
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && !frame.isEmpty
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
