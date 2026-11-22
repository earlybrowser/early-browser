// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Foundation
import Testing
import WebKit

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

    @Test func visibilityChangesRefreshZeroAndExistingMatchesWithoutRetyping() async throws {
        let fixture = PageToolFixture(pages: ["visibility": """
            <!doctype html><style>.concealed, [data-hide] { display:none }</style>
            <p id="first" hidden>needle</p>
            <p id="second" class="concealed">needle</p>
            <p id="third" style="visibility:hidden">needle</p>
            """])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("visibility")
        let manager = fixture.manager
        manager.showFind(tab.id)
        manager.updateFind(tab.id, query: "needle")
        #expect(try await waitForAnswer(fixture, tab.id, "initially hidden").matchCount == 0)

        _ = try await fixture.evaluate("document.querySelector('#first').hidden = false", in: tab)
        #expect(manager.findNext(tab.id))
        var state = try await waitForAnswer(fixture, tab.id, "revealed")
        #expect(state.matchCount == 1 && state.currentIndex == 0)

        _ = try await fixture.evaluate("""
            document.querySelector('#second').className = '';
            document.querySelector('#third').style.visibility = 'visible';
            """, in: tab)
        #expect(manager.findNext(tab.id))
        state = try await waitForAnswer(fixture, tab.id, "class and style")
        #expect(state.matchCount == 3 && state.currentIndex == 1)

        _ = try await fixture.evaluate("document.querySelector('#second').setAttribute('data-hide', '')", in: tab)
        #expect(manager.findNext(tab.id, backwards: true))
        state = try await waitForAnswer(fixture, tab.id, "previous after hiding current")
        #expect(state.matchCount == 2 && state.currentIndex == 0)

        _ = try await fixture.evaluate("document.querySelector('#second').removeAttribute('data-hide')", in: tab)
        #expect(manager.findNext(tab.id))
        state = try await waitForAnswer(fixture, tab.id, "revealed again")
        #expect(state.matchCount == 3 && state.currentIndex == 1)

        // An in-place CSSOM change has no mutation record. Existing ranges
        // still need to be checked before stepping.
        _ = try await fixture.evaluate("document.styleSheets[0].insertRule('#second {display:none}')", in: tab)
        #expect(manager.findNext(tab.id))
        state = try await waitForAnswer(fixture, tab.id, "CSSOM hid current")
        #expect(state.matchCount == 2 && state.currentIndex == 1)

        _ = try await fixture.evaluate("document.styleSheets[0].deleteRule(0)", in: tab)
        #expect(manager.findNext(tab.id, backwards: true))
        state = try await waitForAnswer(fixture, tab.id, "CSSOM revealed previous")
        #expect(state.matchCount == 3 && state.currentIndex == 1)
    }

    @Test func shadowTreeEditsRefreshHighlightsAndKeepDocumentOrder() async throws {
        let fixture = PageToolFixture(pages: ["shadow": """
            <!doctype html><p id="before">needle</p><div id="host"></div><p id="after">needle</p>
            <script>
            const root = document.querySelector('#host').attachShadow({mode:'open'});
            root.innerHTML = '<style>.concealed {visibility:hidden}</style><p id="inside">needle</p><div id="late"></div>';
            </script>
            """])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("shadow")
        let manager = fixture.manager, view = try fixture.page(tab).view
        manager.showFind(tab.id)
        manager.updateFind(tab.id, query: "needle")
        #expect(try await waitForAnswer(fixture, tab.id, "shadow search").matchCount == 3)
        #expect(manager.findNext(tab.id))
        #expect(try await waitForAnswer(fixture, tab.id, "selected shadow match").currentIndex == 1)
        let painted = try await view.callAsyncJavaScript("""
            const root = document.querySelector('#host').shadowRoot;
            const active = [...CSS.highlights.get('early-find-current')][0];
            return [active.startContainer.getRootNode() === root,
                    root.adoptedStyleSheets.some(sheet => sheet.cssRules[0].selectorText === '::highlight(early-find)')];
            """, arguments: [:], in: nil, contentWorld: WebViewManager.findWorld)
        #expect(painted as? [Bool] == [true, true])

        _ = try await fixture.evaluate("root.querySelector('#inside').className = 'concealed'", in: tab)
        #expect(manager.findNext(tab.id))
        var state = try await waitForAnswer(fixture, tab.id, "step out of hidden shadow match")
        #expect(state.matchCount == 2 && state.currentIndex == 1)

        _ = try await fixture.evaluate("""
            root.querySelector('#inside').className = '';
            root.querySelector('#inside').firstChild.data = 'changed';
            root.querySelector('#late').attachShadow({mode:'open'}).append('needle');
            """, in: tab)
        #expect(manager.findNext(tab.id, backwards: true))
        state = try await waitForAnswer(fixture, tab.id, "nested match")
        #expect(state.matchCount == 3 && state.currentIndex == 1)
        _ = try await fixture.evaluate("root.querySelector('#late').shadowRoot.firstChild.remove()", in: tab)
        #expect(manager.findNext(tab.id))
        state = try await waitForAnswer(fixture, tab.id, "removed shadow text")
        #expect(state.matchCount == 2 && state.currentIndex == 1)

        // Attaching a root alone must also be noticed when the other matches stay visible.
        _ = try await fixture.evaluate("root.querySelector('#inside').attachShadow({mode:'open'}).textContent = 'needle'", in: tab)
        #expect(manager.findNext(tab.id, backwards: true))
        state = try await waitForAnswer(fixture, tab.id, "attached root")
        #expect(state.matchCount == 3 && state.currentIndex == 1)
        manager.hideFind(tab.id)
        let cleaned = try await view.callAsyncJavaScript("""
            const root = document.querySelector('#host').shadowRoot;
            return [CSS.highlights.has('early-find'), CSS.highlights.has('early-find-current'),
                    document.adoptedStyleSheets.length > 0, root.adoptedStyleSheets.length > 0];
            """, arguments: [:], in: nil, contentWorld: WebViewManager.findWorld)
        #expect(cleaned as? [Bool] == [false, false, false, false])
    }

    @Test func findCoalescesMutationsAndReleasesItsObserverWhenThePageLeaves() async throws {
        let fixture = PageToolFixture(pages: ["visibility": "<p hidden>needle</p><p>needle</p>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("visibility")
        let view = try fixture.page(tab).view
        let result = try await view.callAsyncJavaScript("""
            const observe = MutationObserver.prototype.observe;
            const disconnect = MutationObserver.prototype.disconnect;
            const observing = new Set();
            MutationObserver.prototype.observe = function(...args) {
                observing.add(this);
                return observe.apply(this, args);
            };
            MutationObserver.prototype.disconnect = function() {
                observing.delete(this);
                return disconnect.call(this);
            };
            const createWalker = document.createTreeWalker;
            let scans = 0;
            document.createTreeWalker = function(...args) {
                scans++;
                return createWalker.apply(this, args);
            };
            try {
                \(WebViewManager.findLibrary)
                const find = window.__earlyFind, paragraph = document.querySelector('p');
                const before = find.update('needle', 0, 1000);
                for (let n = 0; n < 5; n++) {
                    paragraph.hidden = !paragraph.hidden;
                    await Promise.resolve();
                }
                const coalesced = scans === 1;
                const after = find.step('needle', -1, 1000);
                const refreshed = scans === 2 && after.count === 2;
                window.dispatchEvent(new Event('pagehide'));
                return [before.count === 1, coalesced, refreshed, observing.size === 0, !CSS.highlights.has('early-find')];
            } finally {
                MutationObserver.prototype.observe = observe;
                MutationObserver.prototype.disconnect = disconnect;
                document.createTreeWalker = createWalker;
            }
            """, arguments: [:], in: nil, contentWorld: WebViewManager.findWorld)
        #expect(result as? [Bool] == [true, true, true, true, true])
    }
}
