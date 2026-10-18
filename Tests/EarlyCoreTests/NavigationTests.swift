// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct NavigationTests {
    @Test @MainActor func backgroundTabPreservesSelectionAndCommandBar() throws {
        let coordinator = BrowserCoordinator(startup: .firstLaunch)
        let originalURL = URL(string: "https://example.com/current")!
        let original = coordinator.navigate(to: originalURL, target: .newTab(spaceID: coordinator.activeSpaceID))
        coordinator.presentCommandBar(.navigateCurrentTab)
        coordinator.updateQuery("unfinished edit")
        let presentation = coordinator.commandBar
        let backgroundURL = URL(string: "https://example.com/background")!
        let id = coordinator.openBackgroundTab(to: backgroundURL)
        let tab = try #require(coordinator.tabStore.tab(id: id))
        #expect(tab.currentURL == backgroundURL)
        #expect(tab.spaceID == coordinator.activeSpaceID)
        #expect(tab.isOpen)
        #expect(coordinator.activeTabID == original)
        #expect(coordinator.commandBar == presentation)
        #expect(coordinator.tabStore.tabs.count == 2)
    }

    @Test(arguments: [
        (" example.com/path ", "https://example.com/path"),
        ("localhost:8080/test", "http://localhost:8080/test"),
        ("127.0.0.1:8000/", "http://127.0.0.1:8000/"),
        ("[::1]:8080/", "http://[::1]:8080/"),
        ("example.com:8443", "https://example.com:8443"),
        ("https://example.com/?a=b#c", "https://example.com/?a=b#c")
    ])
    func resolvesAddresses(pair: (String, String)) throws {
        #expect(try NavigationInput().resolve(pair.0).absoluteString == pair.1)
    }

    @Test func searchIsCorrectlyEscaped() throws {
        let url = try NavigationInput().resolve("swift & native #browser")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "www.google.com")
        #expect(parts.path == "/search")
        #expect(parts.queryItems == [URLQueryItem(name: "q", value: "swift & native #browser")])
    }

    @Test(arguments: ["", "  \n", "javascript:alert(1)", "data:text/html,test", "file:///etc/hosts",
                      "ftp://example.com", "https://", "https://example.com:99999", "https://user:password@example.com"])
    func rejectsUnsafeOrInvalidInput(_ text: String) {
        #expect(throws: (any Error).self) { try NavigationInput().resolve(text) }
    }

    @Test @MainActor func submissionCreatesOnlyWhenAcceptedAndLocationReusesIdentity() throws {
        let coordinator = BrowserCoordinator(startup: .firstLaunch)
        coordinator.updateQuery("example.com")
        let request = try #require(coordinator.navigationRequest())
        #expect(coordinator.tabStore.tabs.isEmpty)
        let id = try #require(coordinator.navigate(to: NavigationInput().resolve(request.query), target: request.target))
        #expect(coordinator.tabStore.tabs.count == 1)
        #expect(coordinator.commandBar == nil)
        coordinator.presentCommandBar(.navigateCurrentTab)
        coordinator.updateQuery("https://swift.org")
        let location = try #require(coordinator.navigationRequest())
        #expect(coordinator.navigate(to: try NavigationInput().resolve(location.query), target: location.target) == id)
        #expect(coordinator.tabStore.tabs.count == 1)
        #expect(coordinator.tabStore.tab(id: id)?.currentURL.host == "swift.org")
        coordinator.presentCommandBar(.newTab)
        coordinator.dismissCommandBar()
        #expect(coordinator.tabStore.tabs.count == 1)
        #expect(coordinator.activeTabID == id)
    }

    @Test @MainActor func closeAndReopenPreservesOrderAndIdentity() throws {
        let coordinator = BrowserCoordinator(startup: .returningSession)
        let url = URL(string: "https://example.com")!
        let first = try #require(coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)))
        let second = try #require(coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)))
        coordinator.closeTab(first)
        #expect(coordinator.activeTabID == second)
        #expect(coordinator.reopenLastTab() == first)
        #expect(coordinator.tabStore.tabs.map(\.id) == [first, second])
        #expect(coordinator.activeTabID == first)
        #expect(coordinator.recentlyClosed.isEmpty)
    }

    @Test @MainActor func closedHistoryIsBoundedAndSessionContainsNoTransientBar() throws {
        let coordinator = BrowserCoordinator(startup: .firstLaunch)
        for _ in 0..<25 {
            coordinator.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: coordinator.activeSpaceID))
            coordinator.closeActiveTab()
        }
        #expect(coordinator.recentlyClosed.count == 20)
        coordinator.presentCommandBar(.newTab)
        coordinator.updateQuery("unsent private query")
        let json = try JSONEncoder().encode(coordinator.session)
        #expect(!String(decoding: json, as: UTF8.self).contains("unsent private query"))
        #expect(coordinator.session.tabs.isEmpty)
        try coordinator.session.validate()
    }
}
