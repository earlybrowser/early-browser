import CoreGraphics
import Foundation

/// A frozen layout for one drag. Preview offsets never feed back into hit testing,
/// and durable tab order is changed only when the user releases inside the section.
public struct SidebarReorderLayout {
    public struct Slot {
        public let id: UUID
        public let frame: CGRect
        public init(id: UUID, frame: CGRect) { self.id = id; self.frame = frame }
    }

    public let source: UUID
    public let slots: [Slot]
    public let bounds: CGRect
    public let grid: Bool

    public init(source: UUID, slots: [Slot], bounds: CGRect, grid: Bool) {
        self.source = source
        self.slots = slots
        self.bounds = bounds
        self.grid = grid
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
            return point.y > slot.frame.midY
        }.count
        var result = others.map(\.id)
        result.insert(source, at: index)
        return result
    }

    public func offset(for id: UUID, at point: CGPoint) -> CGSize {
        guard id != source, let original = slots.first(where: { $0.id == id }),
              let index = order(at: point).firstIndex(of: id) else { return .zero }
        return CGSize(width: slots[index].frame.midX - original.frame.midX,
                      height: slots[index].frame.midY - original.frame.midY)
    }

    public func drop(at point: CGPoint) -> (target: UUID, after: Bool)? {
        let order = order(at: point)
        guard bounds.contains(point), order != slots.map(\.id),
              let index = order.firstIndex(of: source) else { return nil }
        return index > 0 ? (order[index - 1], true) : (order[1], false)
    }
}
