// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Foundation
import Testing

/// Find in page against real WebKit documents in unshown views.
@Suite(.serialized) @MainActor
struct PageFindTests {
    private static let article = """
        <!doctype html><title>Find</title><body style="margin:0;font:16px sans-serif">
        <p id="first">Early is a browser. EARLY is calm.</p>
        <p>Split Ea<b>rly</b> across tags, and early
        browser across a line.</p>
        <p>Ends with Ear</p><p>ly in the next paragraph.</p>
        <p style="display:none">Early hidden</p>
        <script>const early = 'Early in a script';</script>
        <textarea>Early in a field</textarea>
        <div style="height:2400px"></div>
        <p id="last">Early far below.</p>
        </body>
        """

    private func waitForAnswer(_ fixture: PageToolFixture, _ id: UUID, _ label: String) async throws -> PageFindState {
        try await fixture.waitUntil(label) { fixture.manager.pages[id]?.find?.isSearching == false }
        return try #require(fixture.manager.pages[id]?.find)
    }

    @Test func findCountsVisibleTextAcrossInlineTagsButNotBlocksAndWrapsBothWays() async throws {
        let fixture = PageToolFixture(pages: ["article": Self.article])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("article")
        let manager = fixture.manager
        let before = try await fixture.evaluate("document.body.innerHTML", in: tab) as? String
        #expect(manager.showFind(tab.id) && manager.pages[tab.id]?.find?.query == "")

        manager.updateFind(tab.id, query: "early")
        var state = try await waitForAnswer(fixture, tab.id, "search")
        // Two in the first paragraph, the split word, "early browser", and the
        // last line; not the hidden, script, field or cross-paragraph text.
        #expect(state.matchCount == 5 && state.currentIndex == 0 && !state.isCapped)

        #expect(manager.findNext(tab.id))
        state = try await waitForAnswer(fixture, tab.id, "next")
        #expect(state.currentIndex == 1)
        #expect(manager.findNext(tab.id, backwards: true) && manager.findNext(tab.id, backwards: true))
        state = try await waitForAnswer(fixture, tab.id, "wrap back")
        #expect(state.currentIndex == 4, "Previous from the first match wraps to the last")
        let scrolled = try await fixture.evaluate("window.scrollY", in: tab) as? Double ?? 0
        #expect(scrolled > 1000, "The current match is scrolled into view")

        manager.updateFind(tab.id, query: "early   browser")
        state = try await waitForAnswer(fixture, tab.id, "spaces")
        #expect(state.matchCount == 1, "Whitespace in the query matches any run of spaces or a line break")
        manager.updateFind(tab.id, query: "ear ly")
        state = try await waitForAnswer(fixture, tab.id, "blocks")
        #expect(state.matchCount == 0 && state.currentIndex == nil)
        manager.updateFind(tab.id, query: "a.b")
        state = try await waitForAnswer(fixture, tab.id, "literal")
        #expect(state.matchCount == 0, "Queries are literal text, not patterns")

        // Highlights never rewrite the page, and the page cannot see the search.
        #expect(try await fixture.evaluate("document.body.innerHTML", in: tab) as? String == before)
        #expect(try await fixture.evaluate("typeof window.__earlyFind", in: tab) as? String == "undefined")
    }

    @Test func closingSelectsTheMatchAndCommandGReopensWithTheLastSearch() async throws {
        let fixture = PageToolFixture(pages: ["article": Self.article, "other": "<p>Another early page, early.</p>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("article")
        let other = try await fixture.open("other")
        let manager = fixture.manager
        #expect(!manager.canFindNext(tab.id), "Nothing to repeat before the first search")
        manager.showFind(tab.id)
        manager.updateFind(tab.id, query: "calm")
        #expect(try await waitForAnswer(fixture, tab.id, "calm").matchCount == 1)
        manager.hideFind(tab.id)
        #expect(manager.pages[tab.id]?.find == nil)
        let selected = try await fixture.evaluate("String(getSelection())", in: tab) as? String
        #expect(selected == "calm", "The found text stays selected, as in Safari")
        #expect(await manager.findSelection(tab.id) == "calm")

        manager.updateFind(other.id, query: "ignored")
        #expect(manager.pages[other.id]?.find == nil, "Typing goes nowhere while the bar is closed")
        #expect(manager.canFindNext(other.id) && manager.findNext(other.id))
        let state = try await waitForAnswer(fixture, other.id, "repeat")
        #expect(state.query == "calm" && state.matchCount == 0, "Command-G reopens with the shared last search")
    }

    @Test func changedAndNewDocumentsAreSearchedAgainAndLargeCountsAreCapped() async throws {
        let many = "<p>" + String(repeating: "word ", count: PageFindState.matchLimit + 5) + "</p>"
        let fixture = PageToolFixture(pages: ["article": Self.article, "many": many])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("article")
        let manager = fixture.manager
        manager.showFind(tab.id)
        manager.updateFind(tab.id, query: "calm")
        #expect(try await waitForAnswer(fixture, tab.id, "calm").matchCount == 1)
        _ = try await fixture.evaluate("document.getElementById('first').insertAdjacentHTML('afterend', '<p>Calm again</p>')", in: tab)
        #expect(manager.findNext(tab.id))
        var state = try await waitForAnswer(fixture, tab.id, "changed")
        #expect(state.matchCount == 2 && state.currentIndex == 1, "A changed page is searched again from the old match")

        manager.load(fixture.url("many"), in: tab)
        try await fixture.waitUntil("navigate") {
            manager.pages[tab.id]?.view.url == fixture.url("many") && manager.pages[tab.id]?.isLoading == false
        }
        manager.updateFind(tab.id, query: "word")
        state = try await waitForAnswer(fixture, tab.id, "many")
        #expect(state.matchCount == PageFindState.matchLimit && state.isCapped)
        #expect(state.query == "word")
    }
}
