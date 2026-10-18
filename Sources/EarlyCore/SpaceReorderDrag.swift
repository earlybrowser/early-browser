// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A transient, horizontal preview over a frozen catalog. Only a valid release
/// commits the order; pointer movement and edge scrolling never change selection.
public struct SpaceReorderDrag: Equatable, Sendable {
    public let ids: [UUID]
    public let source: UUID
    public let width: Double
    public private(set) var viewportOffset: Double
    public private(set) var destinationIndex: Int
    public private(set) var pointerX: Double
    public private(set) var pointerY = 16.0
    private let grabOffset: Double
    private let sourceIndex: Int
    private var pointerIsValid = true
    private static let tolerance = 3.0
    private var stride: Double { SpaceNavigation.footerItemWidth }

    public init?(ids: [UUID], source: UUID, width: Double, viewportOffset: Double, startX: Double) {
        guard ids.count > 1, Set(ids).count == ids.count, let index = ids.firstIndex(of: source),
              width.isFinite, width >= SpaceNavigation.footerItemWidth,
              viewportOffset.isFinite, startX.isFinite else { return nil }
        let viewport = min(width, Double(ids.count) * SpaceNavigation.footerItemWidth)
        let offset = min(max(0, viewportOffset), Double(ids.count) * SpaceNavigation.footerItemWidth - viewport)
        let left = Double(index) * SpaceNavigation.footerItemWidth - offset
        guard (0...viewport).contains(startX), startX >= left, startX <= left + SpaceNavigation.footerItemWidth,
              left < viewport, left + SpaceNavigation.footerItemWidth > 0 else { return nil }
        self.ids = ids
        self.source = source
        self.sourceIndex = index
        self.destinationIndex = index
        self.width = viewport
        self.viewportOffset = offset
        self.pointerX = startX
        self.grabOffset = startX - (left + SpaceNavigation.footerItemWidth / 2)
    }

    public var order: [UUID] {
        var result = ids
        result.remove(at: sourceIndex)
        result.insert(source, at: destinationIndex)
        return result
    }

    public var beforeID: UUID? {
        guard destinationIndex < ids.count - 1 else { return nil }
        return ids[destinationIndex < sourceIndex ? destinationIndex : destinationIndex + 1]
    }

    public var hasMoved: Bool { destinationIndex != sourceIndex }
    public var canDrop: Bool {
        pointerIsValid && pointerX >= -stride / 2 && pointerX <= width + stride / 2
            && pointerY >= -8 && pointerY <= 40
    }

    private var sourceCenter: Double {
        min(width - stride / 2, max(stride / 2, pointerX - grabOffset))
    }

    public func offset(for id: UUID) -> Double {
        guard let index = ids.firstIndex(of: id) else { return 0 }
        return offset(at: index)
    }

    private func offset(at index: Int) -> Double {
        if index == sourceIndex { return sourceCenter + viewportOffset - (Double(index) + 0.5) * stride }
        if sourceIndex < index, index <= destinationIndex { return -stride }
        if destinationIndex <= index, index < sourceIndex { return stride }
        return 0
    }

    public func isVisible(_ id: UUID) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        let left = Double(index) * stride + offset(at: index) - viewportOffset
        return left < width && left + stride > 0
    }

    /// Small hysteresis prevents neighbors twitching at an insertion boundary.
    @discardableResult public mutating func update(pointerX: Double, pointerY: Double = 16) -> Bool {
        guard pointerX.isFinite, pointerY.isFinite else { pointerIsValid = false; return false }
        pointerIsValid = true
        self.pointerX = pointerX
        self.pointerY = pointerY
        return updateDestination()
    }

    /// Called by the UI's cancellable drag task. Keeping the dragged icon in
    /// viewport coordinates lets it stay under the pointer while neighbors scroll.
    @discardableResult public mutating func autoScrollStep() -> Bool {
        guard canDrop else { return false }
        let edge = min(24, width / 3)
        let direction = pointerX < edge ? -1.0 : (pointerX > width - edge ? 1.0 : 0)
        let next = min(Double(ids.count) * stride - width, max(0, viewportOffset + direction * 4))
        guard next != viewportOffset else { return false }
        viewportOffset = next
        updateDestination()
        return true
    }

    @discardableResult private mutating func updateDestination() -> Bool {
        let previous = destinationIndex
        let center = sourceCenter + viewportOffset
        while destinationIndex < ids.count - 1,
              center > Double(destinationIndex + 1) * stride + Self.tolerance { destinationIndex += 1 }
        while destinationIndex > 0,
              center < Double(destinationIndex) * stride - Self.tolerance { destinationIndex -= 1 }
        return previous != destinationIndex
    }
}
