// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import Testing

/// Unshown native windows only; no application launch or input synthesis.
@Suite(.serialized) @MainActor
struct WindowStartupPresentationTests {
    @Test(arguments: [BrowserPreferences.Appearance.light, .dark])
    func launchCallbackPreservesSavedAppearanceBeforeBootstrap(appearance: BrowserPreferences.Appearance) throws {
        let application = NSApplication.shared
        let previous = application.appearance
        let suite = "local.early.tests.startup.appearance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            application.appearance = previous
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(appearance.rawValue, forKey: "browserAppearance")
        let preferences = BrowserPreferences(defaults: defaults)
        EarlyAppDelegate.applyAppearance(preferences.appearance)
        let expected: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        #expect(application.appearance?.name == expected)

        // The launch notification can precede async session bootstrap. It must
        // not reset the already-applied choice to the system appearance.
        let delegate = EarlyAppDelegate()
        delegate.applyAppearance()
        #expect(application.appearance?.name == expected)

        EarlyAppDelegate.applyAppearance(.system)
        #expect(application.appearance == nil)
    }

    @Test func waitsForContentAndLayoutWithoutOrderingWindow() async throws {
        let window = makeWindow()
        let content = LayoutProbe(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content
        window.alphaValue = 0.75
        let presentation = BrowserWindowStartupPresentation()
        defer { presentation.detach(); window.close() }
        var presentations = 0
        presentation.update(window: window, contentReady: false) { presentations += 1 }
        #expect(window.alphaValue == 0 && window.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.alphaValue == 0 && presentations == 0)

        content.needsLayout = true
        let layouts = content.layoutCount
        presentation.update(window: window, contentReady: true) {
            #expect(content.layoutCount > layouts)
            #expect(!window.isVisible && !window.isKeyWindow)
            presentations += 1
        }
        #expect(window.alphaValue == 0 && presentations == 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.alphaValue == 0.75 && !window.ignoresMouseEvents)
        #expect(presentations == 1)

        // Later SwiftUI updates must not hide or re-present a live window.
        presentation.update(window: window, contentReady: false) { presentations += 1 }
        presentation.update(window: window, contentReady: true) { presentations += 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.alphaValue == 0.75 && presentations == 1)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func readinessCanBeWithdrawnBeforePresentation() async throws {
        let window = makeWindow()
        let presentation = BrowserWindowStartupPresentation()
        defer { presentation.detach(); window.close() }
        var presented = false
        presentation.update(window: window, contentReady: true) { presented = true }
        presentation.update(window: window, contentReady: false) { presented = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!presented && window.alphaValue == 0 && window.ignoresMouseEvents)
        presentation.update(window: window, contentReady: true) { presented = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(presented && window.alphaValue == 1 && !window.ignoresMouseEvents)
    }

    @Test func detachingCancelsPresentationAndRestoresOriginalWindowState() async throws {
        let window = makeWindow()
        window.alphaValue = 0.5
        window.ignoresMouseEvents = true
        let presentation = BrowserWindowStartupPresentation()
        defer { presentation.detach(); window.close() }
        var presentations = 0
        presentation.update(window: window, contentReady: true) { presentations += 1 }
        presentation.detach()
        #expect(window.alphaValue == 0.5 && window.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(30))
        #expect(presentations == 0)

        presentation.update(window: window, contentReady: true) { presentations += 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.alphaValue == 0.5 && window.ignoresMouseEvents)
        #expect(presentations == 1)
    }

    @Test func pendingCallbackCannotRevealAnotherWindow() async throws {
        let first = makeWindow(), second = makeWindow()
        let presentation = BrowserWindowStartupPresentation()
        defer { presentation.detach(); first.close(); second.close() }
        var presentations = 0
        presentation.update(window: first, contentReady: true) { presentations += 1 }
        presentation.update(window: second, contentReady: false) { presentations += 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(first.alphaValue == 1 && !first.ignoresMouseEvents)
        #expect(second.alphaValue == 0 && second.ignoresMouseEvents)
        #expect(presentations == 0)
        presentation.update(window: second, contentReady: true) { presentations += 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(second.alphaValue == 1 && !second.ignoresMouseEvents)
        #expect(presentations == 1)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private final class LayoutProbe: NSView {
        var layoutCount = 0
        override func layout() { super.layout(); layoutCount += 1 }
    }
}
