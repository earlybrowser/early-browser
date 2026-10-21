// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import Testing

/// Native-window configuration only: no windows are shown and no UI events are
/// synthesized. On-screen material compositing remains a manual visual check.
@Suite(.serialized) @MainActor
struct SettingsWindowAppearanceTests {
    @Test func hidesVisibleTitleWithoutReplacingNativeWindowControls() throws {
        let window = makeWindow()
        defer { window.close() }
        window.title = "Early Settings"
        let originalStyle = window.styleMask
        let content = window.contentView
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = try kinds.map { try #require(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview)

        // SwiftUI can update its background repeatedly. Configuration must be
        // idempotent and must not replace the content host or traffic lights.
        for _ in 0..<2 { BrowserSettingsWindowAppearance.configure(window) }

        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Early Settings")
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask == originalStyle.union(.fullSizeContentView))
        #expect(window.contentView === content)
        #expect(!window.isVisible)
        for (index, kind) in kinds.enumerated() {
            #expect(window.standardWindowButton(kind) === buttons[index])
            #expect(buttons[index].superview === parents[index])
        }
    }

    @Test func attachmentConfiguresOnlyItsOwnWindowWithoutInterceptingInput() throws {
        let settings = makeWindow()
        let other = makeWindow()
        defer { settings.close(); other.close() }
        let otherStyle = other.styleMask
        let otherTitleVisibility = other.titleVisibility
        let otherTransparency = other.titlebarAppearsTransparent
        let decoration = BrowserSettingsWindowAppearance.AppearanceView()
        let content = try #require(settings.contentView)

        content.addSubview(decoration)

        #expect(settings.titleVisibility == .hidden)
        #expect(settings.styleMask.contains(.fullSizeContentView))
        #expect(settings.titlebarAppearsTransparent)
        #expect(decoration.hitTest(.zero) == nil)
        #expect(!decoration.isAccessibilityElement())
        #expect(!decoration.acceptsFirstResponder)
        #expect(other.styleMask == otherStyle)
        #expect(other.titleVisibility == otherTitleVisibility)
        #expect(other.titlebarAppearsTransparent == otherTransparency)
        #expect(!settings.isVisible && !other.isVisible)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
