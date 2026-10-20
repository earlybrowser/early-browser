// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct WebViewManagerTests {
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

    @Test func nativeHistoryGesturesAndMagnificationSurviveReuseForNormalAndPopupViews() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page",
                             currentURL: URL(string: "https://example.com")!)
        let view = manager.prepare(tab).view
        #expect(view.allowsBackForwardNavigationGestures)
        #expect(view.allowsMagnification)
        #expect(view.magnification == 1)
        view.magnification = 1.5
        #expect(manager.prepare(tab).view === view)
        #expect(view.allowsBackForwardNavigationGestures)
        #expect(view.magnification == 1.5)
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = .nonPersistent()
        supplied.applicationNameForUserAgent = "SuppliedPopup"
        let popupTab = BrowserTab(spaceID: tab.spaceID, profileID: profile, title: "Popup",
                                  currentURL: tab.currentURL)
        let popup = manager.prepare(popupTab, configuration: supplied).view
        #expect(popup.allowsBackForwardNavigationGestures)
        #expect(popup.allowsMagnification)
        #expect(popup.magnification == 1)
        #expect(popup.configuration.websiteDataStore === supplied.websiteDataStore)
        #expect(popup.configuration.applicationNameForUserAgent == "SuppliedPopup")
        #expect(manager.creationCount == 2)
    }

    @Test func fullscreenAndProfileStoreAreSharedWithoutAlteringSuppliedConfiguration() {
        _ = NSApplication.shared
        let profile = UUID()
        let first = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        let second = WebViewManager(profileID: profile, ephemeral: true, websiteDataStore: first.websiteDataStore,
                                    observesMemoryPressure: false)
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
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
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

    @Test func tabMutingSurvivesNavigationButNeverLeaksIntoOtherTabsOrReopenedPages() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Media",
                             currentURL: URL(string: "https://example.com")!)
        let other = BrowserTab(spaceID: tab.spaceID, profileID: profile, title: "Other", currentURL: tab.currentURL)
        let page = manager.prepare(tab)
        let background = manager.prepare(other)
        #expect(!page.isMuted && !background.isMuted)
        #expect(manager.setMuted(true, for: tab.id))
        #expect(page.isMuted && !background.isMuted)
        let state = manager.updateMediaActivity(in: page.view, token: "frame", playing: false)
        #expect(state?["muted"] as? Bool == true)
        #expect(state?["revision"] as? Int == 1)
        manager.webView(page.view, didCommit: nil)
        #expect(page.isMuted && !page.isPlayingMedia)
        manager.webViewWebContentProcessDidTerminate(page.view)
        #expect(page.isMuted && !page.isPlayingMedia)
        #expect(manager.setMuted(false, for: tab.id))
        #expect(!page.isMuted && !background.isMuted)
        #expect(manager.setMuted(true, for: tab.id))
        manager.discard(tabID: tab.id)
        #expect(!manager.setMuted(true, for: tab.id))
        #expect(manager.updateMediaActivity(in: page.view, token: "late", playing: true) == nil)
        #expect(!manager.prepare(tab).isMuted)
        #expect(manager.creationCount == 3)
    }

    @Test func departingFramesStopContributingMediaActivity() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Media",
                             currentURL: URL(string: "https://example.com")!)
        let page = manager.prepare(tab)
        manager.updateMediaActivity(in: page.view, token: "frame", playing: true)
        #expect(page.isPlayingMedia)
        manager.updateMediaActivity(in: page.view, token: "frame", playing: true, removed: true)
        #expect(!page.isPlayingMedia)
    }

    @Test func viewsAreLazyReusedAndExplicitlyReleased() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
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
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
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
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
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
