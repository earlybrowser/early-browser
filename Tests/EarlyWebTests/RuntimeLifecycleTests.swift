// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct RuntimeLifecycleTests {
    private func manager(profile: UUID) -> WebViewManager {
        _ = NSApplication.shared
        return WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["early-runtime"]),
            faviconStore: FaviconStore { _, _, _ in nil }) {
            $0.setURLSchemeHandler(RuntimePages(), forURLScheme: "early-runtime")
        }
    }

    private func tab(profile: UUID, space: UUID = UUID(), path: String = "one") -> BrowserTab {
        BrowserTab(spaceID: space, profileID: profile, title: path, currentURL: URL(string: "early-runtime://fixture/\(path)")!)
    }

    @Test func registrationPresentationAndClosedPinsNeverAllocateViews() {
        let profile = UUID(), manager = manager(profile: profile)
        var tabs = (0..<100).map { tab(profile: profile, path: String($0)) }
        tabs += (0..<20).map { number in
            var pin = tab(profile: profile, path: "pin-\(number)")
            pin.pinnedURL = pin.currentURL
            pin.isOpen = false
            return pin
        }
        #expect(manager.reconcile(tabs: tabs))
        #expect(manager.lifecycles.count == 120)
        #expect(manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[1].id))
        #expect(manager.liveViewCount == 0 && manager.creationCount == 0 && manager.registeredControllerCount == 0)
        #expect(manager.lifecycles.values.allSatisfy { $0.state == .unloaded && !$0.ownsView })
        #expect(manager.lifecycle(for: tabs[0].id).isVisible && !manager.lifecycle(for: tabs[0].id).isFocused)
        #expect(manager.lifecycle(for: tabs[1].id).isFocused)
        #expect(manager.reconcile(tabs: []))
        #expect(manager.lifecycles.isEmpty && manager.visibleTabIDs.isEmpty && manager.focusedTabID == nil)
    }

    @Test func loadsFinishInTheRightVisibilityAndSwitchingReusesTheSameViews() async throws {
        let profile = UUID(), manager = manager(profile: profile)
        defer { manager.discardAll() }
        let first = tab(profile: profile), second = tab(profile: profile, path: "two")
        manager.reconcile(tabs: [first, second])
        manager.setPresentation(visibleTabIDs: [first.id], focusedTabID: first.id)
        manager.load(first.currentURL, in: first)
        #expect(manager.lifecycle(for: first.id).state == .loading)
        manager.load(second.currentURL, in: second)
        #expect(manager.lifecycle(for: second.id).state == .loading)
        let firstView = try #require(manager.existingView(for: first.id))
        let secondView = try #require(manager.existingView(for: second.id))
        try await waitUntil { manager.lifecycle(for: first.id).state == .active && manager.lifecycle(for: second.id).state == .background }

        for _ in 0..<5 {
            manager.setPresentation(visibleTabIDs: [second.id], focusedTabID: second.id)
            manager.activate(second)
            #expect(manager.lifecycle(for: first.id).state == .background)
            #expect(manager.lifecycle(for: second.id).state == .active)
            manager.setPresentation(visibleTabIDs: [first.id, second.id], focusedTabID: first.id)
            #expect(manager.lifecycle(for: first.id).state == .active && manager.lifecycle(for: second.id).state == .active)
            #expect(manager.lifecycle(for: first.id).isFocused && !manager.lifecycle(for: second.id).isFocused)
        }
        #expect(manager.existingView(for: first.id) === firstView && manager.existingView(for: second.id) === secondView)
        #expect(manager.creationCount == 2)
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        #expect(manager.lifecycles.values.allSatisfy { $0.state == .background })
    }

    @Test func processFailureAndExplicitReloadPreserveTheLiveIdentity() async throws {
        let profile = UUID(), manager = manager(profile: profile)
        defer { manager.discardAll() }
        let tab = tab(profile: profile)
        manager.reconcile(tabs: [tab])
        manager.setPresentation(visibleTabIDs: [tab.id], focusedTabID: tab.id)
        manager.load(tab.currentURL, in: tab)
        try await waitUntil { manager.lifecycle(for: tab.id).state == .active }
        let page = try #require(manager.pages[tab.id])
        manager.webViewWebContentProcessDidTerminate(page.view)
        #expect(manager.lifecycle(for: tab.id).state == .failed)
        #expect(page.failure != nil && !page.isLoading)
        manager.activate(tab)
        #expect(manager.lifecycle(for: tab.id).state == .failed && manager.creationCount == 1)
        manager.reload(tab.id)
        #expect(manager.lifecycle(for: tab.id).state == .loading && page.failure == nil)
        try await waitUntil { manager.lifecycle(for: tab.id).state == .active }
        #expect(manager.pages[tab.id] === page && manager.creationCount == 1)
    }

    @Test func disposalRejectsOldDelegatesMessagesAndQueuedRefreshesAfterRecreation() async throws {
        let profile = UUID(), manager = manager(profile: profile)
        defer { manager.discardAll() }
        let tab = tab(profile: profile)
        let retired = manager.prepare(tab)
        retired.view.loadHTMLString("<title>Retired document</title>", baseURL: nil)
        manager.discard(tabID: tab.id)
        #expect(manager.lifecycle(for: tab.id).state == .discarded)
        #expect(retired.view.navigationDelegate == nil && retired.view.uiDelegate == nil)
        #expect(manager.registeredControllerCount == 0)
        manager.load(tab.currentURL, in: tab)
        let replacement = try #require(manager.pages[tab.id])
        #expect(replacement !== retired && replacement.view !== retired.view)
        #expect(manager.updateMediaActivity(in: retired.view, token: "late", playing: true) == nil)
        manager.webViewWebContentProcessDidTerminate(retired.view)
        manager.webView(retired.view, didFail: nil, withError: URLError(.notConnectedToInternet))
        // Loading and title KVO are asynchronous independent notifications.
        // Wait for the document whose metadata this assertion actually checks.
        try await waitUntil {
            manager.lifecycle(for: tab.id).state == .background && replacement.view.title == "Runtime fixture"
        }
        #expect(replacement.failure == nil && !replacement.isPlayingMedia)
        #expect(replacement.view.title == "Runtime fixture")
        #expect(manager.creationCount == 2)
    }

    @Test func sharedPopupControllersStayRegisteredUntilTheirFinalOwnerCloses() async throws {
        let profile = UUID(), manager = manager(profile: profile)
        defer { manager.discardAll() }
        let first = tab(profile: profile), second = tab(profile: profile, path: "popup")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(RuntimePages(), forURLScheme: "early-runtime")
        let opener = manager.prepare(first, configuration: configuration)
        let popup = manager.prepare(second, configuration: configuration)
        #expect(opener.view.configuration.userContentController === popup.view.configuration.userContentController)
        #expect(manager.registeredControllerCount == 1)
        manager.discard(tabID: first.id)
        #expect(manager.registeredControllerCount == 1 && manager.pages[second.id] === popup)
        manager.load(second.currentURL, in: second)
        try await waitUntil { manager.lifecycle(for: second.id).state == .background }
        // Exercise the actual registered bridge, not just the manager's native
        // callback, after its opener has relinquished the shared controller.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            popup.view.callAsyncJavaScript("""
                await window.webkit.messageHandlers.earlyMediaActivity.postMessage({token:'popup',playing:true});
                return true;
                """, arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
        #expect(popup.isPlayingMedia && popup.view.navigationDelegate === manager)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            popup.view.callAsyncJavaScript("""
                window.webkit.messageHandlers.earlyPageInteraction.postMessage({token:'popup-edit',removed:false});
                return true;
                """, arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
        try await waitUntil { popup.hasUnsavedInput }
        manager.discard(tabID: second.id)
        #expect(manager.registeredControllerCount == 0 && manager.liveViewCount == 0)
    }

    @Test func closedAndDeletedTabsLeaveNoOwnedViewsObserversOrGrowingRuntimeCatalog() {
        let profile = UUID(), manager = manager(profile: profile)
        for _ in 0..<25 {
            autoreleasepool {
                let tab = tab(profile: profile)
                manager.reconcile(tabs: [tab])
                weak var releasedPage: BrowserPage?
                do {
                    let page = manager.prepare(tab)
                    releasedPage = page
                    manager.discard(tabID: tab.id)
                    #expect(page.view.navigationDelegate == nil && page.view.uiDelegate == nil)
                }
                #expect(releasedPage == nil, "Observers and script handlers must not retain the retired page owner")
                manager.reconcile(tabs: [])
                #expect(manager.lifecycles.isEmpty && manager.liveViewCount == 0 && manager.registeredControllerCount == 0)
            }
        }
        #expect(manager.creationCount == 25)
    }

    @Test func foreignMetadataAndInvalidFocusDoNotChangeTheCurrentOwner() {
        let profile = UUID(), manager = manager(profile: profile)
        let own = tab(profile: profile), foreign = tab(profile: UUID())
        manager.reconcile(tabs: [own])
        manager.setPresentation(visibleTabIDs: [own.id], focusedTabID: own.id)
        let before = manager.lifecycles
        #expect(!manager.reconcile(tabs: [own, foreign]))
        #expect(!manager.setPresentation(visibleTabIDs: [foreign.id], focusedTabID: foreign.id))
        #expect(!manager.setPresentation(visibleTabIDs: [], focusedTabID: own.id))
        #expect(manager.lifecycles == before && manager.focusedTabID == own.id)
        #expect(manager.creationCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RuntimePages.Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class RuntimePages: NSObject, WKURLSchemeHandler {
    enum Failure: Error { case timeout }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let data = Data("<!doctype html><title>Runtime fixture</title><p>Local page</p>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
