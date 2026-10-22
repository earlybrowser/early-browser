// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyWeb
import ObjectiveC
import Testing
import WebKit

@MainActor private enum KeyWindowEmulation {
    static weak var window: NSWindow?
    static var resent: [String] = []
}

extension NSApplication {
    /// Test-only stand-in while exchanged with `sendEvent(_:)`. A real app's
    /// key window receives WebKit's re-sent key-down; unshown test windows
    /// cannot become key, so route only those events to the test window.
    @objc fileprivate func earlyTests_sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let window = KeyWindowEmulation.window else {
            return earlyTests_sendEvent(event) // The original implementation.
        }
        KeyWindowEmulation.resent.append(event.charactersIgnoringModifiers ?? "")
        window.sendEvent(event)
    }
}

/// Local pages in an unshown window. Events go to that window object only and
/// are never posted to the system; no app launch or UI automation.
@Suite(.serialized) @MainActor
struct WebsiteKeyRoutingTests {
    final class RecordingWindow: NSWindow {
        var unhandledKeys: [String] = []
        // AppKit's default implementation beeps; record that fallback instead.
        override func noResponder(for eventSelector: Selector) {
            if eventSelector == #selector(NSResponder.keyDown(with:)) {
                unhandledKeys.append(NSApp.currentEvent?.charactersIgnoringModifiers ?? "")
            }
        }
    }

    @Test func unhandledKeyPolicyEndsOnlyPlainWebsiteKeys() {
        #expect(!UnhandledPageKey.keepsStandardFallback(keyCode: 17, modifiers: [])) // T
        #expect(!UnhandledPageKey.keepsStandardFallback(keyCode: 49, modifiers: [.shift])) // Space
        #expect(!UnhandledPageKey.keepsStandardFallback(keyCode: 124, modifiers: [.function, .numericPad])) // Right Arrow
        #expect(!UnhandledPageKey.keepsStandardFallback(keyCode: 53, modifiers: [.option])) // Escape
        #expect(UnhandledPageKey.keepsStandardFallback(keyCode: 48, modifiers: [])) // Tab
        #expect(UnhandledPageKey.keepsStandardFallback(keyCode: 48, modifiers: [.shift]))
        #expect(UnhandledPageKey.keepsStandardFallback(keyCode: 38, modifiers: [.command])) // Command-J
        #expect(UnhandledPageKey.keepsStandardFallback(keyCode: 0, modifiers: [.control]))
    }

    @Test func websiteKeysRunOnceWithoutReachingTheUnhandledKeyAlert() async throws {
        _ = NSApplication.shared
        let window = RecordingWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        window.contentView = view
        let original = try #require(class_getInstanceMethod(NSApplication.self, #selector(NSApplication.sendEvent(_:))))
        let routed = try #require(class_getInstanceMethod(NSApplication.self, #selector(NSApplication.earlyTests_sendEvent(_:))))
        method_exchangeImplementations(original, routed)
        KeyWindowEmulation.window = window
        defer {
            method_exchangeImplementations(original, routed)
            KeyWindowEmulation.window = nil
            KeyWindowEmulation.resent = []
            window.close()
        }
        // Like a media site's shortcuts, the page acts on keys without
        // preventing their default; only "p" is explicitly prevented.
        view.loadHTMLString("""
        <html><body><input id="field"><script>
        window.keys = []
        document.addEventListener('keydown', event => {
          if (event.target.id !== 'field') keys.push(event.key)
          if (event.key === 'p') event.preventDefault()
        })
        </script></body></html>
        """, baseURL: nil)
        let loaded = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isLoading || view.url == nil {
            guard ContinuousClock.now < loaded else { throw WaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.makeFirstResponder(view))

        func event(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw WaitFailure.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let arrow = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        for (characters, keyCode, modifiers) in [("t", UInt16(17), NSEvent.ModifierFlags()), (" ", 49, []),
                                                 (arrow, 124, [.function, .numericPad]), ("p", 35, []), ("a", 0, [])] {
            window.sendEvent(try event(characters, keyCode: keyCode, modifiers: modifiers))
        }
        // WebKit completes key events in order: once the last one returns,
        // every earlier key has been handled or re-sent.
        try await waitUntil { KeyWindowEmulation.resent.contains("a") }
        let pageKeys = try await view.evaluateJavaScript("keys.join('|')") as? String
        #expect(pageKeys == "t| |ArrowRight|p|a", "Each website key runs exactly once")
        #expect(KeyWindowEmulation.resent.contains("t") && !KeyWindowEmulation.resent.contains("p"))
        #expect(window.unhandledKeys.isEmpty, "Declined plain keys must not reach AppKit's alert")

        _ = try await view.evaluateJavaScript("document.getElementById('field').focus()")
        window.sendEvent(try event("x", keyCode: 7))
        let typedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var typed: String?
        repeat {
            typed = try await view.evaluateJavaScript("document.getElementById('field').value") as? String
            if typed == "x" { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < typedDeadline
        #expect(typed == "x" && !KeyWindowEmulation.resent.contains("x"), "Text entry stays with the page")

        // An unassigned shortcut keeps AppKit's standard fallback.
        #expect(window.performKeyEquivalent(with: try event("j", keyCode: 38, modifiers: [.command])))
        try await waitUntil { window.unhandledKeys == ["j"] }
    }

    private enum WaitFailure: Error { case timeout }
}
