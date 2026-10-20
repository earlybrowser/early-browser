// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct ProfileIsolationTests {
    @Test func profileWindowsShareCookiesButOtherProfilesAndTheirPopupsDoNot() async throws {
        _ = NSApplication.shared
        let personalID = UUID(), workID = UUID()
        let personal = WebViewManager(profileID: personalID, ephemeral: true, observesMemoryPressure: false)
        let sibling = WebViewManager(profileID: personalID, ephemeral: true, websiteDataStore: personal.websiteDataStore,
                                     observesMemoryPressure: false)
        let work = WebViewManager(profileID: workID, ephemeral: true, observesMemoryPressure: false)
        defer { personal.discardAll(); sibling.discardAll(); work.discardAll() }
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "login", .value: "personal"]))
        await personal.websiteDataStore.httpCookieStore.setCookie(cookie)
        #expect(await sibling.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == "login" && $0.value == "personal" })
        #expect(await work.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        let tab = BrowserTab(spaceID: UUID(), profileID: workID, title: "Work", currentURL: URL(string: "https://example.com")!)
        let view = work.prepare(tab).view
        #expect(view.configuration.websiteDataStore === work.websiteDataStore)
        #expect(view.configuration.websiteDataStore !== personal.websiteDataStore)
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = work.websiteDataStore
        let popup = work.prepare(BrowserTab(spaceID: tab.spaceID, profileID: workID, title: "Popup", currentURL: tab.currentURL), configuration: supplied)
        #expect(popup.view.configuration.websiteDataStore === work.websiteDataStore)
        #expect(await popup.view.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
    }
}
