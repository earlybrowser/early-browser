// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Testing

/// Back/Forward lists come from the tab's own public WebKit history.
@Suite(.serialized) @MainActor
struct HistoryListTests {
    @Test func listsAreNearestFirstAndJumpsMoveWithinTheSameTab() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title><p>1</p>", "two": "<title>Two</title><p>2</p>",
                                              "three": "<title>Three</title><p>3</p>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("one")
        let manager = fixture.manager
        for path in ["two", "three"] {
            manager.load(fixture.url(path), in: tab)
            try await fixture.waitUntil(path) {
                manager.pages[tab.id]?.view.url == fixture.url(path) && manager.pages[tab.id]?.isLoading == false
            }
        }
        #expect(manager.historyList(tab.id, forward: false).map(\.title) == ["Two", "One"])
        #expect(manager.historyList(tab.id, forward: false).map(\.offset) == [-1, -2])
        #expect(manager.historyList(tab.id, forward: true).isEmpty)
        #expect(manager.historyList(tab.id, forward: false, limit: 1).map(\.title) == ["Two"])

        #expect(manager.goToHistory(tab.id, offset: -2))
        try await fixture.waitUntil("back to one") {
            manager.pages[tab.id]?.view.url == fixture.url("one") && manager.pages[tab.id]?.isLoading == false
        }
        #expect(manager.historyList(tab.id, forward: true).map(\.title) == ["Two", "Three"])
        #expect(!manager.goToHistory(tab.id, offset: -1) && !manager.goToHistory(tab.id, offset: 0) && !manager.goToHistory(tab.id, offset: 5))
        #expect(manager.goToHistory(tab.id, offset: 2))
        try await fixture.waitUntil("forward to three") { manager.pages[tab.id]?.view.url == fixture.url("three") }
    }
}
