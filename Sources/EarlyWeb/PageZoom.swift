// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Keyboard and menu page zoom for one tab. Trackpad pinch and Smart Zoom use
/// WebKit's separate magnification and are never changed here.
@MainActor
extension WebViewManager {
    /// Safari's zoom steps, from 50% to 300%.
    public static let zoomLevels: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    public func canZoom(_ id: UUID, by step: Int) -> Bool {
        guard let page = pages[id], page.view.url != nil else { return false }
        return Self.zoomLevel(after: page.zoom, step: step) != nil
    }

    @discardableResult
    public func zoom(_ id: UUID, by step: Int) -> Bool {
        guard canZoom(id, by: step), let page = pages[id],
              let next = Self.zoomLevel(after: page.zoom, step: step) else { return false }
        setZoom(next, for: id)
        return true
    }

    public func canResetZoom(_ id: UUID) -> Bool {
        guard let page = pages[id] else { return false }
        return page.zoom != 1
    }

    @discardableResult
    public func resetZoom(_ id: UUID) -> Bool {
        guard canResetZoom(id) else { return false }
        setZoom(1, for: id)
        return true
    }

    /// The next level in that direction, so an in-between value snaps to a step.
    static func zoomLevel(after current: Double, step: Int) -> Double? {
        if step > 0 { return zoomLevels.first { $0 > current + 0.001 } }
        if step < 0 { return zoomLevels.last { $0 < current - 0.001 } }
        return nil
    }

    func setZoom(_ zoom: Double, for id: UUID) {
        guard let page = pages[id] else { return }
        page.zoom = zoom
        page.view.pageZoom = zoom
        zoomChoices[id] = zoom == 1 ? nil : zoom
    }
}
