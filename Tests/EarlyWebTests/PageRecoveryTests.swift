// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct PageRecoveryTests {
    private func setup() -> (WebViewManager, BrowserTab, RecoveryPages) {
        _ = NSApplication.shared
        let profile = UUID(), fixture = RecoveryPages()
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Saved title",
            currentURL: URL(string: "early-recovery://fixture/page")!)
        let manager = WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["early-recovery"]),
            faviconStore: FaviconStore { _, _, _ in nil }, observesMemoryPressure: false) {
                $0.setURLSchemeHandler(fixture, forURLScheme: "early-recovery")
            }
        manager.reconcile(tabs: [tab])
        manager.setPresentation(visibleTabIDs: [tab.id], focusedTabID: tab.id)
        manager.activate(tab)
        return (manager, tab, fixture)
    }

    @Test func visibleProcessFailureRetriesOnceAndExplicitReloadCanRetryAgain() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let page = try #require(manager.pages[tab.id])
        manager.webViewWebContentProcessDidTerminate(page.view)
        #expect(page.processTerminated && page.failure != nil)
        try await wait { fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .active }
        #expect(manager.pages[tab.id] === page && manager.creationCount == 1)
        #expect(page.failure == nil && !page.processTerminated)
        manager.webViewWebContentProcessDidTerminate(page.view)
        // Give the queued recovery/refresh tasks a chance to run. A site which
        // crashes repeatedly must stay failed rather than reload indefinitely.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .failed)
        manager.reload(tab.id)
        try await wait { fixture.loads == 3 && manager.lifecycle(for: tab.id).state == .active }
        #expect(page.failure == nil)
    }

    @Test func backgroundFailureWaitsForSelectionAndEveryVisibleSplitPaneCanRecover() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let page = try #require(manager.pages[tab.id])
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        manager.webViewWebContentProcessDidTerminate(page.view)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.loads == 1 && page.processTerminated)
        let other = BrowserTab(spaceID: tab.spaceID, profileID: tab.profileID,
            title: "Other pane", currentURL: tab.currentURL)
        manager.reconcile(tabs: [tab, other])
        manager.setPresentation(visibleTabIDs: [tab.id, other.id], focusedTabID: other.id)
        manager.activate(tab)
        try await wait { fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .active }
        #expect(!manager.lifecycle(for: tab.id).isFocused && manager.lifecycle(for: tab.id).isVisible)
        #expect(manager.existingView(for: other.id) == nil)
    }

    @Test func closingOrSwitchingAwayCancelsQueuedRecovery() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let retired = try #require(manager.pages[tab.id])
        manager.webViewWebContentProcessDidTerminate(retired.view)
        manager.discard(tabID: tab.id)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.loads == 1 && manager.liveViewCount == 0)
        manager.activate(tab)
        try await wait { fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .active }
        let replacement = try #require(manager.pages[tab.id])
        manager.webViewWebContentProcessDidTerminate(replacement.view)
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.loads == 2 && replacement.processTerminated)
        manager.setPresentation(visibleTabIDs: [tab.id], focusedTabID: tab.id)
        manager.activate(tab)
        try await wait { fixture.loads == 3 && manager.lifecycle(for: tab.id).state == .active }
    }

    @Test func editedDocumentRequiresExplicitReloadAndOldPageCannotRecoverReplacement() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let old = try #require(manager.pages[tab.id])
        manager.updatePageInteraction(in: old.view, token: "form", removed: false)
        manager.webViewWebContentProcessDidTerminate(old.view)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.loads == 1 && old.hasUnsavedInput && old.failure != nil)
        manager.discard(tabID: tab.id)
        manager.activate(tab)
        manager.webViewWebContentProcessDidTerminate(old.view)
        try await wait { fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .active }
        #expect(manager.pages[tab.id] !== old && manager.pages[tab.id]?.failure == nil)
    }

    @Test func recoveryUsesTheLatestSinglePageRouteAndNavigationAllowsANewRetry() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let page = try #require(manager.pages[tab.id])
        let route = URL(string: "early-recovery://fixture/changed")!
        try await page.view.evaluateJavaScript("history.pushState({}, '', '/changed')")
        try await wait { page.requestedURL == route }
        manager.webViewWebContentProcessDidTerminate(page.view)
        try await wait { fixture.loads == 2 && manager.lifecycle(for: tab.id).state == .active }
        #expect(page.view.url == route)
        let next = URL(string: "early-recovery://fixture/next")!
        manager.load(next, in: tab)
        try await wait { fixture.loads == 3 && manager.lifecycle(for: tab.id).state == .active }
        manager.webViewWebContentProcessDidTerminate(page.view)
        try await wait { fixture.loads == 4 && manager.lifecycle(for: tab.id).state == .active }
        #expect(page.view.url == next && manager.pages[tab.id] === page)
    }

    @Test func provisionalFailureKeepsTheRequestedAddressForExplicitRetry() async throws {
        let (manager, tab, fixture) = setup()
        defer { manager.discardAll() }
        try await wait { manager.lifecycle(for: tab.id).state == .active }
        let page = try #require(manager.pages[tab.id])
        let unavailable = URL(string: "early-recovery://fixture/unavailable")!
        manager.load(unavailable, in: tab)
        try await wait { fixture.loads == 2 && page.failure != nil && !page.view.isLoading }
        #expect(page.requestedURL == unavailable)
        manager.reload(tab.id)
        try await wait { fixture.loads == 3 && page.failure != nil && !page.view.isLoading }
        #expect(page.requestedURL == unavailable && manager.pages[tab.id] === page)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RecoveryPages.Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class RecoveryPages: NSObject, WKURLSchemeHandler {
    enum Failure: Error { case timeout }
    var loads = 0
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        loads += 1
        if url.path == "/unavailable" {
            task.didFailWithError(URLError(.notConnectedToInternet))
            return
        }
        let data = Data("<!doctype html><title>Recovered page</title><p>Ready</p>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
