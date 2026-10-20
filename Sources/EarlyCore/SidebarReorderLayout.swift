// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Empty saved sections advertise their drop targets for the entire drag.
/// Hover changes emphasis, not visibility; populated folders keep their own
/// pointer-scoped feedback instead of an extra empty-section outline.
/// A lifted item is absent from the preview, not from durable membership.
public struct SidebarSavedSectionPreview: Equatable, Sendable {
    public let showsEmptyTarget: Bool
    public let showsOutline: Bool
    public let isActive: Bool
    public let height: CGFloat
    /// Reuse the lifted item's slot instead of adding a second empty row. The
    /// source view and its gesture stay mounted until drop or cancellation.
    public let sourceSlotID: UUID?

    public init(section: TabStore.Section, itemIDs: [UUID], draggingItemID: UUID?, isTargeted: Bool) {
        showsEmptyTarget = section != .regular && !itemIDs.contains { $0 != draggingItemID }
        showsOutline = draggingItemID != nil && showsEmptyTarget
        isActive = showsOutline && isTargeted
        height = section == .favorites ? SidebarReorderLayout.favoriteHeight : 34
        sourceSlotID = showsOutline ? itemIDs.first { $0 == draggingItemID } : nil
    }
}

/// A frozen layout for one drag. Preview offsets never feed back into hit testing,
/// and durable tab order is changed only when the user releases inside the section.
public struct SidebarReorderLayout {
    public struct Slot {
        public let id: UUID
        public let frame: CGRect
        public let hitFrame: CGRect
        public init(id: UUID, frame: CGRect, hitFrame: CGRect? = nil) {
            self.id = id; self.frame = frame; self.hitFrame = hitFrame ?? frame
        }
    }

    public let source: UUID
    public let slots: [Slot]
    public let bounds: CGRect
    public let grid: Bool
    /// True when the source is not a real member of this list (cross-section or
    /// into a folder). A trailing placeholder slot still lets neighbors shift.
    public let foreign: Bool
    /// The last settled insertion index in this same container. Small movements
    /// across a row midpoint should not repeatedly shuffle its neighbors.
    public let retainedIndex: Int?
    public static let insertionTolerance: CGFloat = 6

    public init(source: UUID, slots: [Slot], bounds: CGRect, grid: Bool, foreign: Bool = false,
                retainedIndex: Int? = nil) {
        self.source = source
        self.slots = slots
        self.bounds = bounds
        self.grid = grid
        self.foreign = foreign
        self.retainedIndex = retainedIndex
    }

    public func order(at point: CGPoint) -> [UUID] {
        let original = slots.map(\.id)
        guard bounds.contains(point), original.contains(source) else { return original }
        let others = slots.filter { $0.id != source }
        var index = others.filter { isAfter($0, at: point) }.count
        if let retainedIndex, (0...others.count).contains(retainedIndex) {
            index = retainedIndex
            while index < others.count, isAfter(others[index], at: point, tolerance: Self.insertionTolerance) {
                index += 1
            }
            while index > 0, !isAfter(others[index - 1], at: point, tolerance: -Self.insertionTolerance) {
                index -= 1
            }
        }
        var result = others.map(\.id)
        result.insert(source, at: index)
        return result
    }

    private func isAfter(_ slot: Slot, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        if grid {
            // Include tile-row gaps, with the same directional tolerance used
            // at column midpoints so Favorites do not twitch between slots.
            if point.y > slot.frame.maxY + 3 + tolerance { return true }
            if point.y < slot.frame.minY - 3 + tolerance { return false }
            return point.x > slot.frame.midX + tolerance
        }
        return point.y > slot.hitFrame.midY + tolerance
    }

    public func offset(for id: UUID, at point: CGPoint) -> CGSize {
        guard bounds.contains(point), order(at: point) != slots.map(\.id) else { return .zero }
        guard id != source, let original = slots.first(where: { $0.id == id }),
              let index = order(at: point).firstIndex(of: id), index < slots.count else { return .zero }
        if !grid {
            // An expanded folder moves as one block with all its visible children.
            let ordered = order(at: point)
            let heights = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.frame.height) })
            let y = (slots.first?.frame.minY ?? 0) + ordered.prefix(index).reduce(CGFloat.zero) {
                $0 + (heights[$1] ?? 0) + 4
            }
            return CGSize(width: 0, height: y - original.frame.minY)
        }
        return CGSize(width: slots[index].frame.midX - original.frame.midX,
                      height: slots[index].frame.midY - original.frame.midY)
    }

    /// Compact the source Favorites grid while its tile is previewed elsewhere.
    /// Keep the real slots/gesture alive; only the remaining tiles move visually.
    public func offsetRemovingSource(for id: UUID) -> CGSize {
        guard grid, !foreign, id != source,
              let sourceIndex = slots.firstIndex(where: { $0.id == source }),
              let index = slots.firstIndex(where: { $0.id == id }), index > sourceIndex else { return .zero }
        return CGSize(width: slots[index - 1].frame.midX - slots[index].frame.midX,
                      height: slots[index - 1].frame.midY - slots[index].frame.midY)
    }

    public func drop(at point: CGPoint) -> (target: UUID, after: Bool)? {
        let order = order(at: point)
        guard bounds.contains(point), let index = order.firstIndex(of: source) else { return nil }
        if !foreign, order == slots.map(\.id) { return nil }
        guard order.count > 1 else { return nil }
        return index > 0 ? (order[index - 1], true) : (order[1], false)
    }

    /// Next sibling after the insertion point, or `before == nil` to append.
    public func insertion(at point: CGPoint) -> Insertion? {
        guard bounds.contains(point) else { return nil }
        let order = order(at: point)
        if !foreign, order == slots.map(\.id) { return nil }
        guard let index = order.firstIndex(of: source) else { return nil }
        return Insertion(before: index + 1 < order.count ? order[index + 1] : nil)
    }

    public struct Insertion: Equatable, Sendable {
        public var before: UUID?
    }

    /// A row is retained only when it supplies this same container's insertion
    /// slot. A nil folder is the Pins root, not an absence of a source container.
    public static func vacatesSourceRow(sourceSection: TabStore.Section, sourceFolder: UUID?,
                                        destinationSection: TabStore.Section?, destinationFolder: UUID?) -> Bool {
        destinationSection != sourceSection
            || (destinationSection == .pinned && destinationFolder != sourceFolder)
    }

    public static let favoriteHeight: CGFloat = 43.2
    public static let favoriteRowStride: CGFloat = favoriteHeight + 6

    /// One to four favorites share the width. Larger grids keep four columns,
    /// including a partially filled last row.
    public static func favoriteFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0, bounds.width > 0 else { return [] }
        return (0..<count).map { index in
            let row = index / 4
            let columns = min(4, count)
            let width = max(1, (bounds.width - CGFloat(columns - 1) * 6) / CGFloat(columns))
            return CGRect(x: bounds.minX + CGFloat(index % 4) * (width + 6),
                          y: bounds.minY + CGFloat(row) * favoriteRowStride, width: width, height: favoriteHeight)
        }
    }

    public static func placeholderFrame(after last: CGRect?, bounds: CGRect, grid: Bool, size: CGSize) -> CGRect {
        guard let last else {
            return CGRect(x: bounds.minX, y: bounds.minY, width: max(size.width, 1), height: max(size.height, 1))
        }
        if grid {
            let gap: CGFloat = 6
            let nextX = last.maxX + gap
            if nextX + last.width <= bounds.maxX + 2 {
                return CGRect(x: nextX, y: last.minY, width: last.width, height: last.height)
            }
            return CGRect(x: bounds.minX, y: last.maxY + gap, width: last.width, height: last.height)
        }
        return CGRect(x: last.minX, y: last.maxY + 4, width: last.width, height: max(size.height, 1))
    }
}
