// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import EarlyWeb
import Testing
import WebKit

/// Web Inspector docked beside a page in Early's own page host, in a window
/// that is never shown: it stays with its page across hosts and resizes.
@Suite(.serialized) @MainActor
struct WebInspectorDockingTests {
    /// Opening Web Inspector brings the window it's in to the front. WebKit
    /// may lay the inspector out only in a window on screen, so this one comes
    /// forward as before, but fully transparent and passing every click
    /// through: running the tests shows nothing.
    static func invisibleWindow(_ rect: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle]
        return window
    }

    func inspector(of page: WKWebView) -> NSObject? { page.value(forKey: "_inspector") as? NSObject }

    @Test func aDockedInspectorStaysBesideItsPageThroughTabSwitchesAndResizes() async throws {
        _ = NSApplication.shared
        let suite = "local.early.tests.inspector.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
        let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("EarlyInspector-\(UUID()).sqlite"), input: input)
        let model = BrowserWindowModel(startup: .returningSession, session: BrowserSession(), repository: repository,
                                       input: input, isTesting: true, restorationError: nil, defaults: defaults)
        defer { model.webViews.discardAll() }
        WebViewManager.registerInspectorDefaults()
        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let tab = try #require(model.coordinator.focusedTabID)
        let page = try #require(model.webViews.pages[tab])
        // Like Early's window: content, and the page, run up under the title bar.
        // Within CI's 1024-by-768-point screen.
        let window = Self.invisibleWindow(CGRect(x: 0, y: 0, width: 1000, height: 700))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = root
        let first = WebContentView.HostView(frame: root.bounds)
        root.addSubview(first)
        #expect(first.display(page.view))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while page.isLoading || page.view.url == nil {
            guard ContinuousClock.now < deadline else { Issue.record("load"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        func docked(_ host: WebContentView.HostView) -> (page: CGRect, inspector: CGRect)? {
            guard let inspector = host.dockedInspector else { return nil }
            return (page.view.frame, inspector.frame)
        }
        // WebKit lays the docked inspector out over a few passes (slower on
        // CI): wait for the layout a check expects, then report what is there.
        func settled(_ host: WebContentView.HostView,
                     _ ready: ((page: CGRect, inspector: CGRect)) -> Bool) async throws -> (page: CGRect, inspector: CGRect)? {
            let until = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < until {
                host.layoutSubtreeIfNeeded()
                if let frames = docked(host), ready(frames) { return frames }
                try await Task.sleep(for: .milliseconds(50))
            }
            return docked(host)
        }
        func fills(_ host: WebContentView.HostView) -> ((page: CGRect, inspector: CGRect)) -> Bool {
            { $0.page.union($0.inspector) == host.bounds }
        }

        #expect(model.perform(.toggleWebInspector))
        let opened = try #require(try await settled(first) {
            fills(first)($0) && $0.inspector.minX > $0.page.minX && $0.inspector.height == first.bounds.height
        }, "Web Inspector docks beside the page")
        #expect(opened.page.union(opened.inspector) == first.bounds && opened.inspector.minX > opened.page.minX,
                "On the right of the page: \(opened) in \(first.bounds)")
        #expect(opened.inspector.height == first.bounds.height && opened.page.height == first.bounds.height,
                "As tall as the page, no strip above it under the title bar: \(opened)")
        // WebKit can leave the inspector short of the pane's edge (on CI's macOS
        // 26: 324 of the 500 points beside the page); Early fills the pane.
        let inspectorView = try #require(first.dockedInspector)
        inspectorView.frame = CGRect(x: opened.page.maxX, y: 0, width: 324, height: first.bounds.height)
        let refilled = try #require(try await settled(first, fills(first)))
        #expect(refilled.inspector.maxX == first.bounds.maxX && refilled.inspector.minX == refilled.page.maxX, "\(refilled)")
        #expect(model.isWebInspectorVisible)

        // Switching tabs releases the page; another host shows it again later.
        first.invalidate()
        #expect(first.subviews.isEmpty, "Nothing is left behind in the old host")
        let second = WebContentView.HostView(frame: CGRect(x: 0, y: 0, width: 960, height: 660))
        root.addSubview(second)
        #expect(second.display(page.view))
        let returned = try #require(try await settled(second, fills(second)), "The inspector comes back with its page")
        #expect(returned.page.union(returned.inspector) == second.bounds, "\(returned) in \(second.bounds)")

        // The inspector's own "dock to bottom" puts it below the page.
        let frontend = inspector(of: page.view)?.value(forKey: "inspectorWebView") as? WKWebView
        _ = try await frontend?.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('bottom'); 1")
        let bottom = try #require(try await settled(second) { fills(second)($0) && $0.inspector.width == second.bounds.width })
        #expect(bottom.inspector.maxY <= bottom.page.minY + 1, "Below the page, not above it: \(bottom)")
        #expect(bottom.page.union(bottom.inspector) == second.bounds, "\(bottom) in \(second.bounds)")
        _ = try await frontend?.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('right'); 1")
        _ = try await settled(second) { fills(second)($0) && $0.inspector.width < second.bounds.width }

        second.setFrameSize(CGSize(width: 900, height: 620))
        let resized = try #require(try await settled(second) { fills(second)($0) && $0.inspector.height == second.bounds.height })
        #expect(resized.page.union(resized.inspector) == second.bounds && resized.inspector.height == second.bounds.height,
                "\(resized) in \(second.bounds)")

        #expect(model.perform(.toggleWebInspector))
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while second.dockedInspector != nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(second.dockedInspector == nil && page.view.frame == second.bounds && !model.isWebInspectorVisible)
        #expect(window.alphaValue == 0, "Never visible on screen")
        second.invalidate()
    }
}
