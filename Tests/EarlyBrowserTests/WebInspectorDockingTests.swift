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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
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
        func waitDocked(_ host: WebContentView.HostView) async throws {
            let until = ContinuousClock.now.advanced(by: .seconds(10))
            while docked(host) == nil {
                guard ContinuousClock.now < until else { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        #expect(model.perform(.toggleWebInspector))
        try await waitDocked(first)
        let opened = try #require(docked(first), "Web Inspector docks beside the page")
        #expect(opened.page.union(opened.inspector) == first.bounds && opened.inspector.minX > opened.page.minX, "On the right of the page")
        #expect(model.isWebInspectorVisible)

        // Switching tabs releases the page; another host shows it again later.
        first.invalidate()
        #expect(first.subviews.isEmpty, "Nothing is left behind in the old host")
        let second = WebContentView.HostView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(second)
        #expect(second.display(page.view))
        try await Task.sleep(for: .milliseconds(300))
        let returned = try #require(docked(second), "The inspector comes back with its page")
        #expect(returned.page.union(returned.inspector) == second.bounds)

        // The inspector's own "dock to bottom" puts it below the page.
        let frontend = inspector(of: page.view)?.value(forKey: "inspectorWebView") as? WKWebView
        _ = try await frontend?.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('bottom'); 1")
        try await Task.sleep(for: .milliseconds(800))
        let bottom = try #require(docked(second))
        #expect(bottom.inspector.maxY <= bottom.page.minY + 1, "Below the page, not above it")
        #expect(bottom.page.union(bottom.inspector) == second.bounds)
        _ = try await frontend?.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('right'); 1")
        try await Task.sleep(for: .milliseconds(800))

        second.setFrameSize(CGSize(width: 900, height: 600))
        second.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let resized = try #require(docked(second))
        #expect(resized.page.union(resized.inspector) == second.bounds)

        #expect(model.perform(.toggleWebInspector))
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while second.dockedInspector != nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(second.dockedInspector == nil && page.view.frame == second.bounds && !model.isWebInspectorVisible)
        second.invalidate()
    }
}
