// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct WebViewManagerTests {
    @Test func historyFeedbackWaitsForCommitAndNeverFiresForOrdinaryScrollingOrButtons() throws {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page",
                             currentURL: URL(string: "https://example.com")!)
        let view = try #require(manager.prepare(tab).view as? BrowserWebView)
        var reported: [UUID] = []
        manager.onHistoryGestureNavigation = { reported.append($0) }
        func sample(_ phase: HistoryGestureProvenance.Phase, x: CGFloat) {
            view.updateHistoryGesture(x: x, y: 0, phase: phase, precise: true,
                canNavigate: true, timestamp: ProcessInfo.processInfo.systemUptime)
        }
        manager.back(tab.id)
        manager.forward(tab.id)
        manager.webView(view, didCommit: nil)
        #expect(reported.isEmpty)

        sample(.began, x: 0)
        sample(.changed, x: 100)
        sample(.ended, x: 0)
        // Ordinary horizontal scrolling and unrelated document commits stay silent.
        manager.webView(view, didCommit: nil)
        #expect(reported.isEmpty)
        sample(.began, x: 0)
        sample(.changed, x: 100)
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        #expect(reported.isEmpty) // Even an accepted action isn't a committed navigation yet.
        sample(.ended, x: 0)
        manager.webView(view, didCommit: nil)
        #expect(reported == [tab.id])
        manager.webView(view, didCommit: nil)
        #expect(reported == [tab.id])

        sample(.began, x: 50)
        manager.back(tab.id)
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.webView(view, didCommit: nil)
        sample(.began, x: 50)
        manager.forward(tab.id)
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.webView(view, didCommit: nil)
        view.historyGesture.reset() // The key monitor also resets provenance for shortcuts.
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.webView(view, didCommit: nil)
        #expect(reported == [tab.id])
        let foreign = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        manager.recordHistoryNavigation(in: foreign, navigationType: .backForward, isMainFrame: true)
        manager.webView(foreign, didCommit: nil)
        sample(.began, x: 50)
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.discardAll()
        manager.webView(view, didCommit: nil)
        #expect(reported == [tab.id])
        #expect(manager.liveViewCount == 0 && manager.creationCount == 1)
    }

    @Test func cancelledFailedUnrelatedAndSubframeNavigationsDoNotProduceFeedback() throws {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page",
                             currentURL: URL(string: "https://example.com")!)
        let view = try #require(manager.prepare(tab).view as? BrowserWebView)
        var reported: [UUID] = []
        manager.onHistoryGestureNavigation = { reported.append($0) }
        func begin() {
            view.updateHistoryGesture(x: 50, y: 0, phase: .began, precise: true,
                canNavigate: true, timestamp: ProcessInfo.processInfo.systemUptime)
        }
        for kind in [WKNavigationType.other, .linkActivated, .reload, .formSubmitted] {
            begin()
            manager.recordHistoryNavigation(in: view, navigationType: kind, isMainFrame: true)
            manager.webView(view, didCommit: nil)
        }
        begin()
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: false)
        manager.webView(view, didCommit: nil)
        for code in [NSURLErrorCancelled, NSURLErrorTimedOut] {
            begin()
            manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
            manager.webView(view, didFailProvisionalNavigation: nil,
                withError: NSError(domain: NSURLErrorDomain, code: code))
            manager.webView(view, didCommit: nil)
        }
        begin()
        view.updateHistoryGesture(x: 0, y: 0, phase: .cancelled, precise: true,
            canNavigate: true, timestamp: ProcessInfo.processInfo.systemUptime)
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.webView(view, didCommit: nil)
        begin()
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.stop(tab.id)
        manager.webView(view, didCommit: nil)
        begin()
        manager.recordHistoryNavigation(in: view, navigationType: .backForward, isMainFrame: true)
        manager.webViewWebContentProcessDidTerminate(view)
        manager.webView(view, didCommit: nil)
        #expect(reported.isEmpty)
    }

    @Test func commandClickUsesWebKitButtonMaskRatherThanNSEventButtonIndex() {
        #expect(WebViewManager.isCommandClick(navigationType: .linkActivated, buttonNumber: 1, modifiers: .command))
        #expect(!WebViewManager.isCommandClick(navigationType: .linkActivated, buttonNumber: 1, modifiers: []))
        for button in [0, 2, 4] {
            #expect(!WebViewManager.isCommandClick(navigationType: .linkActivated, buttonNumber: button, modifiers: .command))
        }
        for kind in [WKNavigationType.other, .formSubmitted, .reload, .backForward] {
            #expect(!WebViewManager.isCommandClick(navigationType: kind, buttonNumber: 1, modifiers: .command))
        }
    }

    @Test func nativeMagnificationIsEnabledForNormalAndPopupViewsAndSurvivesReuse() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page",
                             currentURL: URL(string: "https://example.com")!)
        let view = manager.prepare(tab).view
        #expect(view.allowsMagnification)
        #expect(view.magnification == 1)
        view.magnification = 1.5
        #expect(manager.prepare(tab).view === view)
        #expect(view.magnification == 1.5)
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = .nonPersistent()
        supplied.applicationNameForUserAgent = "SuppliedPopup"
        let popupTab = BrowserTab(spaceID: tab.spaceID, profileID: profile, title: "Popup",
                                  currentURL: tab.currentURL)
        let popup = manager.prepare(popupTab, configuration: supplied).view
        #expect(popup.allowsMagnification)
        #expect(popup.magnification == 1)
        #expect(popup.configuration.websiteDataStore === supplied.websiteDataStore)
        #expect(popup.configuration.applicationNameForUserAgent == "SuppliedPopup")
        #expect(manager.creationCount == 2)
    }

    @Test func fullscreenAndProfileStoreAreSharedWithoutAlteringSuppliedConfiguration() {
        _ = NSApplication.shared
        let profile = UUID()
        let first = WebViewManager(profileID: profile, ephemeral: true)
        let second = WebViewManager(profileID: profile, ephemeral: true, websiteDataStore: first.websiteDataStore)
        func tab() -> BrowserTab {
            BrowserTab(spaceID: UUID(), profileID: profile, title: "Page", currentURL: URL(string: "https://example.com")!)
        }
        let one = first.prepare(tab()).view
        let two = second.prepare(tab()).view
        #expect(one.configuration.preferences.isElementFullscreenEnabled)
        #expect(two.configuration.preferences.isElementFullscreenEnabled)
        #expect(one.configuration.websiteDataStore === two.configuration.websiteDataStore)
        let supplied = WKWebViewConfiguration()
        supplied.preferences.isElementFullscreenEnabled = false
        let popup = second.prepare(tab(), configuration: supplied).view
        #expect(!popup.configuration.preferences.isElementFullscreenEnabled)
        first.discardAll()
        second.discardAll()
    }
    @Test func mediaActivityAggregatesFramesAndResetsOnNavigationAndProcessExit() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Media",
                             currentURL: URL(string: "https://example.com")!)
        let page = manager.prepare(tab)
        #expect(!page.isPlayingMedia)
        manager.updateMediaActivity(in: page.view, token: "main", playing: true)
        manager.updateMediaActivity(in: page.view, token: "frame", playing: true)
        manager.updateMediaActivity(in: page.view, token: "main", playing: false)
        #expect(page.isPlayingMedia)
        manager.updateMediaActivity(in: page.view, token: "frame", playing: false)
        #expect(!page.isPlayingMedia)
        manager.updateMediaActivity(in: page.view, token: "main", playing: true)
        manager.webView(page.view, didCommit: nil)
        #expect(!page.isPlayingMedia)
        manager.updateMediaActivity(in: page.view, token: "new-document", playing: true)
        manager.webViewWebContentProcessDidTerminate(page.view)
        #expect(!page.isPlayingMedia)
        manager.discardAll()
        manager.updateMediaActivity(in: page.view, token: "late-message", playing: true)
        #expect(!page.isPlayingMedia)
        #expect(manager.liveViewCount == 0)
    }

    @Test func viewsAreLazyReusedAndExplicitlyReleased() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Example", currentURL: URL(string: "https://example.com")!)
        #expect(manager.liveViewCount == 0)
        let page = manager.prepare(tab)
        #expect(manager.prepare(tab) === page)
        #expect(manager.creationCount == 1)
        // WebKit may expose an unset override as nil or an empty string.
        #expect(page.view.customUserAgent?.isEmpty != false)
        #expect(page.view.configuration.applicationNameForUserAgent == BrowserUserAgent.applicationName)
        #expect(page.view.url == nil)
        manager.discard(tabID: tab.id)
        #expect(manager.liveViewCount == 0)
        #expect(page.view.navigationDelegate == nil)
        #expect(page.view.uiDelegate == nil)
    }

    @Test func tabsShareOneProfileStoreAndSuppliedConfigurationIsHonored() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        func tab() -> BrowserTab {
            BrowserTab(spaceID: UUID(), profileID: profile, title: "Example", currentURL: URL(string: "https://example.com")!)
        }
        let first = manager.prepare(tab())
        let second = manager.prepare(tab())
        #expect(first.view.configuration.websiteDataStore === second.view.configuration.websiteDataStore)
        #expect(!first.view.configuration.websiteDataStore.isPersistent)
        #expect(first.view.customUserAgent?.isEmpty != false)
        #expect(second.view.customUserAgent?.isEmpty != false)
        #expect(first.view.configuration.applicationNameForUserAgent == BrowserUserAgent.applicationName)
        #expect(second.view.configuration.applicationNameForUserAgent == BrowserUserAgent.applicationName)
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = .nonPersistent()
        supplied.applicationNameForUserAgent = "EarlyPopupTest"
        let popup = manager.prepare(tab(), configuration: supplied)
        #expect(popup.view.configuration.websiteDataStore === supplied.websiteDataStore)
        #expect(popup.view.configuration.applicationNameForUserAgent == "EarlyPopupTest")
        #expect(popup.view.customUserAgent?.isEmpty != false)
        #expect(popup.view.url == nil) // Caller must not duplicate WebKit's new-window load.
        manager.discardAll()
        #expect(manager.liveViewCount == 0)
    }

    @Test func repeatedOpenCloseRemovesAllOwnedViewsAndDelegates() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        for _ in 0..<20 {
            autoreleasepool {
                let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Example", currentURL: URL(string: "https://example.com")!)
                let page = manager.prepare(tab)
                manager.discard(tabID: tab.id)
                #expect(page.view.navigationDelegate == nil)
                #expect(page.view.uiDelegate == nil)
                #expect(manager.liveViewCount == 0)
            }
        }
        #expect(manager.creationCount == 20)
    }
}
