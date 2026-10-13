import CoreGraphics
import Foundation

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

    public init(source: UUID, slots: [Slot], bounds: CGRect, grid: Bool, foreign: Bool = false) {
        self.source = source
        self.slots = slots
        self.bounds = bounds
        self.grid = grid
        self.foreign = foreign
    }

    public func order(at point: CGPoint) -> [UUID] {
        let original = slots.map(\.id)
        guard bounds.contains(point), original.contains(source) else { return original }
        let others = slots.filter { $0.id != source }
        let index = others.filter { slot in
            if grid {
                // Include the spacing between tile rows in the nearest row's band.
                if point.y > slot.frame.maxY + 3 { return true }
                if point.y < slot.frame.minY - 3 { return false }
                return point.x > slot.frame.midX
            }
            return point.y > slot.hitFrame.midY
        }.count
        var result = others.map(\.id)
        result.insert(source, at: index)
        return result
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
