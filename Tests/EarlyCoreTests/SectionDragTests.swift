import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct SectionDragTests {
    @Test func conversionsKeepIdentityOriginalPinAndSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let original = URL(string: "https://example.com")!
        let video = URL(string: "https://example.com/video")!
        let id = try #require(browser.navigate(to: original, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.moveTab(id, to: .pinned))
        browser.updateMetadata(id, url: video, title: "Video")
        #expect(browser.moveTab(id, to: .favorites))
        #expect(browser.moveTab(id, to: .pinned))
        #expect(browser.tabStore.tab(id: id)?.pinnedURL == original)
        #expect(browser.tabStore.tab(id: id)?.currentURL == video)
        #expect(browser.activeTabID == id)
        #expect(browser.moveTab(id, to: .regular))
        #expect(browser.tabStore.tab(id: id)?.pinnedURL == nil)
        #expect(browser.moveTab(id, to: .favorites))
        _ = browser.closeTab(id)
        #expect(browser.moveTab(id, to: .pinned))
        #expect(browser.tabStore.tab(id: id)?.isOpen == false)
        #expect(browser.activeTabID == nil)
        #expect(browser.moveTab(id, to: .regular))
        #expect(browser.tabStore.tab(id: id)?.isOpen == true)
        #expect(browser.activeTabID == nil)
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.recentlyClosed.isEmpty)
        try browser.session.validate()
        let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        #expect(restored.tabs == browser.tabStore.tabs)
    }
}
