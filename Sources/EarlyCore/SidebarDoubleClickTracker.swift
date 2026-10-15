import Foundation

/// Observes clicks without delaying the control's normal single-click action.
/// The platform supplies clickCount using the user's double-click interval.
public struct SidebarDoubleClickTracker<ID: Equatable> {
    private var firstClick: ID?
    private var pressed: ID?
    private var origin = CGPoint.zero
    private var clickCount = 0
    private var canRename = false
    private var dragged = false

    public init() {}

    public mutating func mouseDown(on item: ID?, at point: CGPoint, clickCount: Int) {
        canRename = item != nil && item == firstClick && clickCount == 2
        firstClick = nil
        pressed = item
        origin = point
        self.clickCount = clickCount
        dragged = false
    }

    public mutating func mouseDragged(to point: CGPoint) {
        // Match the sidebar reorder gesture's four-point activation threshold.
        if hypot(point.x - origin.x, point.y - origin.y) >= 4 { dragged = true }
    }

    public mutating func mouseUp(on item: ID?, at point: CGPoint) -> ID? {
        mouseDragged(to: point)
        let valid = item != nil && item == pressed && !dragged
        let renamed = valid && canRename ? item : nil
        firstClick = valid && clickCount == 1 ? item : nil
        pressed = nil
        canRename = false
        return renamed
    }
}
