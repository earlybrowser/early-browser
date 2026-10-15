import Foundation
import Testing
@testable import EarlyCore

struct SidebarDoubleClickTrackerTests {
    @Test func renameRequiresSecondReleaseOnTheSameRow() {
        var clicks = SidebarDoubleClickTracker<String>()
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 1)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 2)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == "folder")
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 3)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
    }

    @Test func normalClicksAndDifferentRowsNeverRename() {
        var clicks = SidebarDoubleClickTracker<String>()
        for _ in 0..<3 {
            clicks.mouseDown(on: "folder", at: .zero, clickCount: 1)
            #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
        }
        clicks.mouseDown(on: "other", at: .zero, clickCount: 2)
        #expect(clicks.mouseUp(on: "other", at: .zero) == nil)
    }

    @Test func secondPressDragCancelsRenameEvenAfterReturningToOrigin() {
        var clicks = SidebarDoubleClickTracker<String>()
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 1)
        _ = clicks.mouseUp(on: "folder", at: .zero)
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 2)
        clicks.mouseDragged(to: CGPoint(x: 4, y: 0))
        clicks.mouseDragged(to: .zero)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
    }

    @Test func firstDragAndOutsideReleaseCannotStartDoubleClick() {
        var clicks = SidebarDoubleClickTracker<String>()
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 1)
        // Also reject displacement if AppKit coalesces the drag events.
        #expect(clicks.mouseUp(on: "folder", at: CGPoint(x: 0, y: 4)) == nil)
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 2)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 1)
        #expect(clicks.mouseUp(on: nil, at: .zero) == nil)
        clicks.mouseDown(on: "folder", at: .zero, clickCount: 2)
        #expect(clicks.mouseUp(on: "folder", at: .zero) == nil)
    }
}
