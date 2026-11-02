// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import ObjectiveC
import SwiftUI
import Testing

/// Unshown native windows only: no app launch, visible window or input
/// synthesis. Hover glyphs and on-screen rendering remain manual checks.
@Suite(.serialized) @MainActor
struct WindowControlsCompatibilityTests {
    private let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    @Test(arguments: [false, true])
    func loadingControlsMatchRestoredSidebarWithoutFlashing(autoHides: Bool) async throws {
        _ = NSApplication.shared
        let suite = "local.early.tests.startup.controls.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(autoHides, forKey: "sidebarAutoHides")
        let preferences = BrowserPreferences(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyStartupControls-\(UUID())")
        let model = BrowserWindowModel(startup: .returningSession, session: BrowserSession(),
            repository: SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite")),
            input: NavigationInput(), isTesting: true, restorationError: nil, defaults: defaults, preferences: preferences)
        model.onSave = { _ in }
        let window = makeWindow()
        window.styleMask.insert(.fullSizeContentView)
        let hosting = NSHostingView(rootView: AnyView(BrowserWindowLoadingView(preferences: preferences)))
        window.contentView = hosting
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            model.cancelWindowInteractions()
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        hosting.layoutSubtreeIfNeeded()
        let buttons = try kinds.map { try #require(window.standardWindowButton($0)) }
        let titlebar = try #require(titlebarContainer(of: window))
        #expect(titlebar.isHidden)
        #expect(buttons.allSatisfy { $0.isHidden == autoHides })
        let loadingFrames = buttons.map { $0.convert($0.bounds, to: hosting) }

        hosting.rootView = AnyView(BrowserWindowView(model: model).transaction { $0.disablesAnimations = true })
        hosting.layoutSubtreeIfNeeded()
        // Include the one-turn native ownership reconciliation after SwiftUI
        // replaces the loading host. The window is never brought on screen.
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        #expect(titlebar.isHidden)
        #expect(WindowControls.ControlsHost.ownsControls(in: window))
        for (index, button) in buttons.enumerated() {
            let restoredFrame = button.convert(button.bounds, to: hosting)
            if autoHides {
                #expect(restoredFrame.maxX <= 0, "The hidden sidebar must not expose its controls at startup")
            } else {
                #expect(!button.isHidden)
                #expect(abs(restoredFrame.minX - loadingFrames[index].minX) < 0.5)
                #expect(abs(restoredFrame.minY - loadingFrames[index].minY) < 0.5)
            }
        }
        #expect(!window.isVisible)
    }

    @Test func verifiesPrivateHookSignaturesBeforeUse() throws {
        let origin = try #require(class_getInstanceMethod(NSView.self, #selector(NSView.setFrameOrigin(_:))))
        let flipped = try #require(class_getInstanceMethod(NSView.self, #selector(getter: NSView.isFlipped)))
        #expect(WindowControls.Compatibility.matchesVoidSignature(origin, arguments: [["{CGPoint=dd}"]]))
        #expect(!WindowControls.Compatibility.matchesVoidSignature(origin, arguments: []))
        #expect(!WindowControls.Compatibility.matchesVoidSignature(origin, arguments: [["B"]]))
        #expect(!WindowControls.Compatibility.matchesVoidSignature(flipped, arguments: []))
        // A changed macOS release should fail here before users notice the
        // standard-controls fallback.
        #expect(WindowControls.Compatibility.lockedWidgetClass != nil)
    }

    @Test func hostsVerifiedButtonsAndRestoresThemOnDetach() throws {
        let window = makeWindow()
        defer { window.close() }
        let buttons = try kinds.map { try #require(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview), frames = buttons.map(\.frame)
        let titlebar = try #require(titlebarContainer(of: window))
        let host = WindowControls.ControlsHost(frame: CGRect(x: 0, y: 0, width: 60, height: 32))
        try #require(window.contentView).addSubview(host)

        #expect(WindowControls.ControlsHost.ownsControls(in: window))
        #expect(titlebar.isHidden)
        for button in buttons {
            #expect(button.superview?.superview === host)
            // AppKit's titlebar resets cannot move a hosted button.
            let origin = button.frame.origin
            button.setFrameOrigin(.zero)
            #expect(button.frame.origin == origin)
        }

        host.detach()
        #expect(!titlebar.isHidden)
        for (index, button) in buttons.enumerated() {
            #expect(button.superview === parents[index])
            #expect(button.frame == frames[index])
        }
    }

    @Test(arguments: [false, true])
    func unverifiedHooksKeepStandardTitlebarButtons(mismatchedClass: Bool) throws {
        let window = makeWindow()
        defer { window.close() }
        let buttons = try kinds.map { try #require(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview), frames = buttons.map(\.frame)
        let titlebar = try #require(titlebarContainer(of: window))
        let host = WindowControls.ControlsHost(frame: CGRect(x: 0, y: 0, width: 60, height: 32),
                                               lockedWidgetClass: mismatchedClass ? NSTextField.self : nil)
        defer { host.detach() }
        try #require(window.contentView).addSubview(host)
        host.synchronize()
        // A sheet must not hide AppKit's own titlebar buttons in this fallback.
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)

        // The fullscreen titlebar hook also stays inert for this window.
        #expect(!WindowControls.ControlsHost.ownsControls(in: window))
        #expect(!titlebar.isHidden)
        #expect(window.titleVisibility == .hidden)
        for (index, button) in buttons.enumerated() {
            #expect(button.superview === parents[index])
            #expect(button.frame == frames[index])
            #expect(!button.isHidden)
        }
    }

    @Test func cornerRadiusTableMatchesTheRunningSystem() throws {
        func radius(_ major: Int) -> CGFloat {
            WindowCornerGeometry.windowRadius(for: OperatingSystemVersion(majorVersion: major, minorVersion: 0,
                                                                          patchVersion: 0))
        }
        #expect([14, 15].map(radius) == [10, 10])
        #expect([26, 27].map(radius) == [16, 16])

        // Test-only drift check; the app no longer reads this private value.
        let window = makeWindow()
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let selector = NSSelectorFromString("_getCachedDefaultWindowCornerRadius")
        guard let method = class_getInstanceMethod(type(of: frame), selector),
              Int(method_getNumberOfArguments(method)) == 2 else { return }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "d" else { return }
        typealias Radius = @convention(c) (AnyObject, Selector) -> CGFloat
        let measured = unsafeBitCast(method_getImplementation(method), to: Radius.self)(frame, selector)
        #expect(WindowCornerGeometry.windowRadius(for: ProcessInfo.processInfo.operatingSystemVersion) == measured)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func titlebarContainer(of window: NSWindow) -> NSView? {
        window.contentView?.superview?.subviews.first { $0.className == "NSTitlebarContainerView" }
    }
}
