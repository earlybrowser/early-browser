import AppKit
import EarlyCore
import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct WebViewManagerTests {
    @Test func viewsAreLazyReusedAndExplicitlyReleased() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Example", currentURL: URL(string: "https://example.com")!)
        #expect(manager.liveViewCount == 0)
        let page = manager.prepare(tab)
        #expect(manager.prepare(tab) === page)
        #expect(manager.creationCount == 1)
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
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = .nonPersistent()
        supplied.applicationNameForUserAgent = "EarlyPopupTest"
        let popup = manager.prepare(tab(), configuration: supplied)
        #expect(popup.view.configuration.websiteDataStore === supplied.websiteDataStore)
        #expect(popup.view.configuration.applicationNameForUserAgent == "EarlyPopupTest")
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
