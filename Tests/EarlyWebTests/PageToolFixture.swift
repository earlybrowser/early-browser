// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Local `early-tools://fixture/<path>` pages for find, zoom, hover, Reader and
/// translation tests. Nothing touches the network.
@MainActor
final class PageToolFixture {
    enum Failure: Error { case timeout(String) }

    let profile = UUID()
    let manager: WebViewManager
    private(set) var tabs: [BrowserTab] = []

    init(pages: [String: String], allowance: Int = 4) {
        _ = NSApplication.shared
        manager = WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["http", "https", "early-tools"]),
            faviconStore: FaviconStore { _, _, _ in nil },
            retentionPolicy: PageRetentionPolicy(maximumInactivePages: allowance),
            observesMemoryPressure: false) {
            $0.setURLSchemeHandler(Pages(pages), forURLScheme: "early-tools")
        }
    }

    func url(_ path: String) -> URL { URL(string: "early-tools://fixture/\(path)")! }

    /// Prepares a tab, loads `path` and waits until WebKit finished it.
    @discardableResult
    func open(_ path: String) async throws -> BrowserTab {
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: path, currentURL: url(path))
        tabs.append(tab)
        manager.reconcile(tabs: tabs)
        // Opened pages stay visible, so retention never discards them mid-test.
        manager.setPresentation(visibleTabIDs: Set(tabs.map(\.id)), focusedTabID: tab.id)
        // A real viewport, so layout-dependent checks (visibility, scrolling) apply.
        manager.prepare(tab).view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        manager.load(url(path), in: tab)
        try await waitUntil("load \(path)") {
            guard let page = manager.pages[tab.id] else { return false }
            return !page.isLoading && !page.view.isLoading && page.view.url == url(path)
        }
        return tab
    }

    func page(_ tab: BrowserTab) throws -> BrowserPage { try #require(manager.pages[tab.id]) }

    func evaluate(_ script: String, in tab: BrowserTab) async throws -> Any? {
        try await manager.pages[tab.id]?.view.evaluateJavaScript(script)
    }

    func waitUntil(_ label: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func cleanup() { manager.discardAll() }

    private final class Pages: NSObject, WKURLSchemeHandler {
        let pages: [String: String]
        init(_ pages: [String: String]) { self.pages = pages }
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            let path = String(url.path.dropFirst())
            let html = pages[path] ?? "<!doctype html><title>Missing</title><p>Missing \(path)</p>"
            let data = Data(html.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
}
