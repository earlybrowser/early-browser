// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Testing

/// Unshown native fixtures only. Events are passed directly to the handler,
/// never posted to NSApp/the system or used to move the user's pointer.
@Suite(.serialized) @MainActor
struct SidebarPointerMonitorTests {
    @MainActor private final class Fixture {
        let window: NSWindow
        let view = BrowserWindowPointerMonitor.PointerView()

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: 50, y: 70, width: 960, height: 640),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = false
            window.contentView = view
        }

        func cleanup() {
            view.stop()
            window.contentView = nil
            window.close()
        }

        func event(at point: CGPoint, type: NSEvent.EventType = .mouseMoved, window: NSWindow? = nil) throws -> NSEvent {
            let location = view.convert(point, to: nil)
            let number = (window ?? self.window).windowNumber
            if type == .mouseEntered || type == .mouseExited {
                return try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                    timestamp: 0, windowNumber: number, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: number, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
    }

    @Test(arguments: [SidebarWidth.minimum, SidebarWidth.defaultValue, 250, SidebarWidth.maximum])
    func repeatedEdgeEntriesRevealWithoutActivatingTheOldSidebarFootprint(sidebarWidth: Double) throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        var revealed = false
        fixture.view.onMove = { point in
            revealed = SidebarRevealRegion.contains(point, sidebarWidth: sidebarWidth, revealed: revealed)
        }
        let y = fixture.view.bounds.midY
        for _ in 0..<5 {
            for x in [120.0, 12, 5, 2] {
                fixture.view.handle(try fixture.event(at: CGPoint(x: x, y: y)))
                #expect(!revealed)
            }
            fixture.view.handle(try fixture.event(at: CGPoint(x: 1, y: y)))
            #expect(revealed)
            // A replaced child overlay can report an exit while the pointer
            // remains inside the window. It must not undo the edge reveal.
            fixture.view.mouseExited(with: try fixture.event(at: CGPoint(x: 1, y: y), type: .mouseExited))
            #expect(revealed)
            for x in [5.0, sidebarWidth / 2, sidebarWidth, sidebarWidth + 5] {
                fixture.view.handle(try fixture.event(at: CGPoint(x: x, y: y)))
                #expect(revealed)
            }
            fixture.view.handle(try fixture.event(at: CGPoint(x: sidebarWidth + 6, y: y)))
            #expect(!revealed, "The retention region ends at the sidebar plus its 6 pt gutter")
            fixture.view.handle(try fixture.event(at: CGPoint(x: sidebarWidth / 2, y: y)))
            #expect(!revealed, "An old sidebar footprint cannot reveal the hidden panel")
            fixture.view.handle(try fixture.event(at: CGPoint(x: 1, y: y)))
            #expect(revealed)
            fixture.view.handle(try fixture.event(at: CGPoint(x: sidebarWidth + 30, y: y)))
            #expect(!revealed)
        }
        #expect(!fixture.window.isVisible && !fixture.view.isAccessibilityElement())
        #expect(fixture.view.hitTest(CGPoint(x: 1, y: y)) == nil)
    }

    @Test func defaultWidthDoesNotKeepTheSidebarVisibleAtTheOldHardCodedUITestPoint() {
        let width = SidebarWidth.defaultValue
        #expect(width == 240)
        #expect(SidebarRevealRegion.contains(CGPoint(x: 245, y: 100), sidebarWidth: width, revealed: true))
        #expect(!SidebarRevealRegion.contains(CGPoint(x: 246, y: 100), sidebarWidth: width, revealed: true))
        #expect(!SidebarRevealRegion.contains(CGPoint(x: 250, y: 100), sidebarWidth: width, revealed: true),
                "The failed CI assertion hovered outside the actual default sidebar and its gutter")
    }

    @Test func nativeCoordinatesAreFlippedAndWindowExitsClearThePointer() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        var received: CGPoint?
        fixture.view.onMove = { received = $0 }
        for point in [CGPoint(x: 1, y: 16), CGPoint(x: 240, y: 400)] {
            fixture.view.handle(try fixture.event(at: point))
            #expect(received == point)
        }
        for point in [CGPoint(x: -1, y: 100), CGPoint(x: 100, y: -1),
                      CGPoint(x: fixture.view.bounds.maxX, y: 100),
                      CGPoint(x: 100, y: fixture.view.bounds.maxY)] {
            fixture.view.mouseExited(with: try fixture.event(at: point, type: .mouseExited))
            #expect(received == nil)
        }
        fixture.view.handle(try fixture.event(at: CGPoint(x: 1, y: 100)))
        #expect(received != nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(received == nil)
    }

    @Test func trackingIsWindowLocalAndReparentingRestoresMouseMovePreferences() throws {
        let fixture = Fixture(), other = Fixture()
        defer { fixture.cleanup(); other.cleanup() }
        var received: CGPoint?
        fixture.view.onMove = { received = $0 }
        let point = CGPoint(x: 1, y: 100)
        fixture.view.handle(try fixture.event(at: point, window: other.window))
        #expect(received == nil)
        #expect(fixture.window.acceptsMouseMovedEvents)
        #expect(fixture.view.trackingAreas.count == 1)

        other.window.contentView = fixture.view
        #expect(!fixture.window.acceptsMouseMovedEvents)
        #expect(other.window.acceptsMouseMovedEvents)
        #expect(fixture.view.trackingAreas.count == 1)
        fixture.view.handle(try fixture.event(at: point)) // The old window is no longer its owner.
        #expect(received == nil)
        fixture.view.handle(try fixture.event(at: point, window: other.window))
        #expect(received == point)
        fixture.view.stop()
        fixture.view.stop() // Cleanup is idempotent and removes observers too.
        #expect(!other.window.acceptsMouseMovedEvents)
        #expect(fixture.view.trackingAreas.isEmpty)
        fixture.view.updateTrackingAreas()
        #expect(fixture.view.trackingAreas.isEmpty)
        fixture.view.handle(try fixture.event(at: CGPoint(x: 10, y: 120), window: other.window))
        #expect(received == point, "A queued event must not reach a stopped monitor")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other.window)
        #expect(received == point)
    }

    @Test func windowChromeDoubleClickFollowsTheSystemTitleBarSetting() {
        #expect(WindowDragRegion.doubleClickAction(nil) == .zoom, "Zoom is the macOS default")
        #expect(WindowDragRegion.doubleClickAction("Maximize") == .zoom)
        #expect(WindowDragRegion.doubleClickAction("Fill") == .zoom)
        #expect(WindowDragRegion.doubleClickAction("Minimize") == .minimize)
        #expect(WindowDragRegion.doubleClickAction("None") == .none)
    }
}
