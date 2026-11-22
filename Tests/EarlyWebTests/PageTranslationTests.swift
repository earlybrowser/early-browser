// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Page translation with a stand-in translator: Apple's on-device models are
/// not available to tests, and page text must never leave the process here.
@Suite(.serialized) @MainActor
struct PageTranslationTests {
    static let french = """
        <!doctype html><html lang="fr"><title>Bonjour</title><body>
        <p id="one">  Le navigateur reste calme pour que la page puisse parler.  </p>
        <p id="two">Les espaces rassemblent les onglets <b>d'un projet</b> et la barre latérale se replie.</p>
        <pre id="code">let x = 1</pre><code>printf("bonjour")</code>
        <p id="keep" translate="no">Nom de marque</p><p class="notranslate">Early Browser</p>
        <div contenteditable="true">Texte que vous écrivez</div><textarea>Champ</textarea>
        <p id="digits">12 345</p>
        </body></html>
        """

    private struct Failure: Error {}

    private func stand(in fixture: PageToolFixture) async throws -> BrowserTab {
        let tab = try await fixture.open("french")
        try await fixture.waitUntil("language") { fixture.manager.pages[tab.id]?.language == "fr" }
        return tab
    }

    @Test func languageComesFromTheTextAndTheAttributeIsOnlyAFallback() {
        let english = "The browser stays quiet so the page can speak, and the sidebar folds away when you want the whole window."
        #expect(WebViewManager.dominantLanguage(text: english, hint: "fr") == "en", "The text outweighs a wrong lang attribute")
        #expect(WebViewManager.dominantLanguage(text: "Hi", hint: "de-DE") == "de")
        #expect(WebViewManager.dominantLanguage(text: "", hint: "") == nil)
        #expect(WebViewManager.dominantLanguage(text: "", hint: "not a language") == nil)
    }

    @Test func languageSamplingReadsAVisiblePrefixWithoutReadingWholeTextNodes() async throws {
        let fixture = PageToolFixture(pages: ["article": """
            <!doctype html><html lang="en"><body>
            <div class="advert" style="display:none"></div><main></main>
            <script>
            document.querySelector('.advert').textContent = 'The advertising caption is written in English. '.repeat(20000);
            document.querySelector('main').textContent = 'La lecture doit rester simple et le navigateur doit rester discret. '.repeat(20000);
            </script>
            </body></html>
            """])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("article")
        let page = try fixture.page(tab)
        try await fixture.waitUntil("detected French") { page.language == "fr" }
        let sample = try #require(try await page.view.callAsyncJavaScript("""
            const substringData = CharacterData.prototype.substringData;
            let units = 0;
            const longNodeReads = [];
            CharacterData.prototype.substringData = function(offset, length) {
                units += length;
                if (this.length > 100000) longNodeReads.push(length);
                return substringData.call(this, offset, length);
            };
            try {
                const sample = (() => { \(WebViewManager.languageSample) })();
                return { ...sample, units, longNodeReads };
            } finally { CharacterData.prototype.substringData = substringData; }
            """, arguments: WebViewManager.languageSampleArguments, in: nil, contentWorld: WebViewManager.translationWorld) as? [String: Any])
        let text = try #require(sample["text"] as? String)
        #expect(text.hasPrefix("La lecture doit rester simple"))
        #expect(text.utf16.count <= 2_000 && sample["longNodeReads"] as? [Int] == [2_000])
        #expect((sample["units"] as? Int ?? .max) <= 8_000)
    }

    @Test func languageSamplingStopsAtItsVisitBudgetAndKeepsTheLanguageHint() async throws {
        let fixture = PageToolFixture(pages: ["deep": """
            <!doctype html><html lang="de-DE"><body><main></main><script>
            let parent = document.querySelector('main');
            for (let n = 0; n < 300; n++) parent = parent.appendChild(document.createElement('span'));
            parent.textContent = 'This English passage appears after the cutoff. '.repeat(10);
            </script></body></html>
            """])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("deep")
        let page = try fixture.page(tab)
        let budget = 64
        let arguments = WebViewManager.languageSampleArguments.merging(["maxVisited": budget]) { _, new in new }
        let sample = try #require(try await page.view.callAsyncJavaScript("""
            const originalStyle = window.getComputedStyle;
            let reads = 0;
            window.getComputedStyle = element => { reads++; return originalStyle(element); };
            try {
                const sample = (() => { \(WebViewManager.languageSample) })();
                return { ...sample, reads };
            } finally { window.getComputedStyle = originalStyle; }
            """, arguments: arguments, in: nil, contentWorld: WebViewManager.translationWorld) as? [String: Any])
        let text = try #require(sample["text"] as? String)
        let hint = try #require(sample["lang"] as? String)
        #expect(text.isEmpty && hint == "de-DE")
        #expect((sample["reads"] as? Int).map { $0 > 0 && $0 <= budget } == true)
        #expect(WebViewManager.dominantLanguage(text: text, hint: hint) == "de")
    }

    @Test func translationReplacesOnlyReadableTextAndShowOriginalRestoresItExactly() async throws {
        let fixture = PageToolFixture(pages: ["french": Self.french])
        defer { fixture.cleanup() }
        var reported: [String?] = []
        fixture.manager.onPageLanguage = { _, language in reported.append(language) }
        let tab = try await stand(in: fixture)
        let manager = fixture.manager
        #expect(reported == ["fr"] && manager.canTranslate(tab.id))
        let before = try await fixture.evaluate("document.body.innerHTML", in: tab) as? String

        var batches: [[String]] = []
        let translated = await manager.translatePage(tab.id) { texts in
            batches.append(texts)
            return texts.map { "[en] " + $0 }
        }
        #expect(translated && manager.pages[tab.id]?.translation == .translated)
        let sent = batches.flatMap { $0 }
        #expect(sent.contains("Le navigateur reste calme pour que la page puisse parler."), "Trimmed text is sent")
        #expect(sent.contains("d'un projet"))
        for kept in ["let x = 1", "printf(\"bonjour\")", "Nom de marque", "Early Browser", "Texte que vous écrivez", "Champ", "12 345"] {
            #expect(!sent.contains(kept), "\(kept) is never translated")
        }
        let one = try await fixture.evaluate("document.getElementById('one').firstChild.data", in: tab) as? String
        #expect(one == "  [en] Le navigateur reste calme pour que la page puisse parler.  ", "Surrounding spaces are kept")
        #expect(try await fixture.evaluate("document.getElementById('code').textContent", in: tab) as? String == "let x = 1")

        manager.showOriginal(tab.id)
        #expect(manager.pages[tab.id]?.translation == .original)
        #expect(try await fixture.evaluate("document.body.innerHTML", in: tab) as? String == before)
        #expect(try await fixture.evaluate("typeof window.__earlyTranslation", in: tab) as? String == "undefined",
                "The page cannot see the translation state")
    }

    @Test func failuresRestoreTheTextAndShowOriginalOrANewPageStopsATranslation() async throws {
        let fixture = PageToolFixture(pages: ["french": Self.french, "next": "<p>Next</p>"])
        defer { fixture.cleanup() }
        let tab = try await stand(in: fixture)
        let manager = fixture.manager
        let before = try await fixture.evaluate("document.body.innerHTML", in: tab) as? String

        #expect(await !manager.translatePage(tab.id) { _ in throw Failure() })
        guard case .failed = manager.pages[tab.id]?.translation else { Issue.record("Expected a failure"); return }
        #expect(try await fixture.evaluate("document.body.innerHTML", in: tab) as? String == before)
        #expect(await !manager.translatePage(tab.id) { texts in Array(texts.dropLast()) }, "A short answer is a failure")
        #expect(try await fixture.evaluate("document.body.innerHTML", in: tab) as? String == before)

        // Show Original while a batch is out: nothing is applied afterwards.
        var calls = 0
        let stopped = await manager.translatePage(tab.id) { texts in
            calls += 1
            manager.showOriginal(tab.id)
            return texts.map { "[en] " + $0 }
        }
        #expect(!stopped && calls == 1 && manager.pages[tab.id]?.translation == .original)
        #expect(try await fixture.evaluate("document.body.innerHTML", in: tab) as? String == before)

        manager.load(fixture.url("next"), in: tab)
        try await fixture.waitUntil("navigate") {
            manager.pages[tab.id]?.view.url == fixture.url("next") && manager.pages[tab.id]?.isLoading == false
        }
        #expect(manager.pages[tab.id]?.translation == .original)
        try await fixture.waitUntil("english") { manager.pages[tab.id]?.language == nil || manager.pages[tab.id]?.language == "en" }
    }

    /// Translate, Show Original, Translate again: the first run's late batch,
    /// or its error, never reaches the page or replaces the second's result.
    @Test func anEarlierTranslationNeverOverwritesALaterOne() async throws {
        let fixture = PageToolFixture(pages: ["french": Self.french])
        defer { fixture.cleanup() }
        let tab = try await stand(in: fixture)
        let manager = fixture.manager
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await manager.translatePage(tab.id) { texts in
                await withCheckedContinuation { releaseFirst = $0 }
                return texts.map { "[old] " + $0 }
            }
        }
        try await fixture.waitUntil("first run waiting") { releaseFirst != nil }
        let page = try fixture.page(tab)
        let oldRun = try #require(page.translationRun)
        manager.showOriginal(tab.id)
        let second = await manager.translatePage(tab.id) { texts in texts.map { "[new] " + $0 } }
        #expect(second && manager.pages[tab.id]?.translation == .translated)
        releaseFirst?.resume()
        #expect(await first.value == false, "The earlier run stops")
        // WebKit commands already issued for the old run can also arrive late.
        _ = try await page.view.callAsyncJavaScript(WebViewManager.translationRestore,
            arguments: ["runID": oldRun.uuidString], in: nil, contentWorld: WebViewManager.translationWorld)
        _ = try await page.view.callAsyncJavaScript(WebViewManager.translationApply,
            arguments: ["runID": oldRun.uuidString, "start": 0, "texts": ["[old]"]],
            in: nil, contentWorld: WebViewManager.translationWorld)
        let text = try await fixture.evaluate("document.getElementById('one').textContent", in: tab) as? String ?? ""
        #expect(text.contains("[new]") && !text.contains("[old]"), "\(text)")
        #expect(manager.pages[tab.id]?.translation == .translated)

        // An earlier run's error doesn't undo the later translation either.
        manager.showOriginal(tab.id)
        var failFirst: CheckedContinuation<Void, Never>?
        let failing = Task { @MainActor in
            await manager.translatePage(tab.id) { _ in
                await withCheckedContinuation { failFirst = $0 }
                throw Failure()
            }
        }
        try await fixture.waitUntil("failing run waiting") { failFirst != nil }
        manager.showOriginal(tab.id)
        #expect(await manager.translatePage(tab.id) { texts in texts.map { "[new] " + $0 } })
        failFirst?.resume()
        #expect(await failing.value == false)
        #expect(manager.pages[tab.id]?.translation == .translated, "Still translated")
        let after = try await fixture.evaluate("document.getElementById('one').textContent", in: tab) as? String ?? ""
        #expect(after.contains("[new]"), "\(after)")
    }

    @Test func cancellingTheSystemTaskRestoresAPartialTranslationAndKeepsSiteEdits() async throws {
        let paragraphs = (0...WebViewManager.translationBatchSize).map { "<p>Article \($0)</p>" }.joined()
        let fixture = PageToolFixture(pages: ["article": "<html lang='fr'><body>\(paragraphs)</body></html>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("article"), page = try fixture.page(tab)
        try await fixture.waitUntil("language detected") { page.language != nil }
        var lastBatch: CheckedContinuation<Void, Never>?
        defer { lastBatch?.resume() }
        let task = Task {
            await fixture.manager.translatePage(tab.id) { texts in
                if texts.count == 1 { await withCheckedContinuation { lastBatch = $0 } }
                return texts.map { "[en] " + $0 }
            }
        }
        try await fixture.waitUntil("last batch suspended") { lastBatch != nil }
        #expect(try await fixture.evaluate("document.querySelector('p').textContent", in: tab) as? String == "[en] Article 0")
        _ = try await fixture.evaluate("document.querySelector('p').firstChild.data = 'Updated'", in: tab)
        task.cancel()
        lastBatch?.resume()
        lastBatch = nil
        #expect(await task.value == false && page.translation == .original)
        #expect(try await fixture.evaluate("document.querySelector('p').textContent", in: tab) as? String == "Updated")
        #expect(try await fixture.evaluate("document.body.textContent.includes('[en]')", in: tab) as? Bool == false)
    }

    @Test(arguments: [false, true])
    func siteEditsSurviveApplyingRestoringAndCollectingAgain(recollect: Bool) async throws {
        let html = """
            <html lang="fr"><body><p id="before">Avant</p><p id="after">Après</p>
            <p id="replaced">Remplacé</p><p id="detached">Détaché</p><p id="stable">  Stable  </p>
            <div id="moved">Déplacé</div><section id="destination"></section></body></html>
            """
        let fixture = PageToolFixture(pages: ["page": html])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("page"), page = try fixture.page(tab)
        try await fixture.waitUntil("language detected") { page.language != nil }
        let result = await fixture.manager.translatePage(tab.id) { texts in
            _ = try await fixture.evaluate("""
                before.firstChild.data = 'Édition avant';
                replaced.replaceChildren(document.createTextNode('Nouveau'));
                window.removedText = detached.firstChild;
                detached.replaceChildren();
                destination.append(moved.firstChild);
                """, in: tab)
            return texts.map { "[en] " + $0 }
        }
        #expect(result)
        let read = "[before.textContent, after.textContent, replaced.textContent, removedText.data, stable.textContent]"
        #expect(try await fixture.evaluate(read, in: tab) as? [String] ==
                ["Édition avant", "[en] Après", "Nouveau", "Détaché", "  [en] Stable  "])
        #expect(try await fixture.evaluate("destination.textContent", in: tab) as? String == "Déplacé")
        _ = try await fixture.evaluate("after.firstChild.data = 'Site updated'; detached.append(removedText);", in: tab)
        if recollect {
            let texts = try await page.view.callAsyncJavaScript(WebViewManager.translationCollect,
                arguments: ["runID": "recollection", "maxNodes": 100, "maxCharacters": 1_000, "maxVisited": 500],
                in: nil, contentWorld: WebViewManager.translationWorld)
            #expect(texts as? [String] == ["Édition avant", "Site updated", "Nouveau", "Détaché", "Stable", "Déplacé"])
        } else { fixture.manager.showOriginal(tab.id) }
        #expect(try await fixture.evaluate(read, in: tab) as? [String] ==
                ["Édition avant", "Site updated", "Nouveau", "Détaché", "  Stable  "])
    }

    @Test(arguments: [false, true])
    func hiddenContentLeavesTheNodeAndCharacterQuotasForRenderedText(manyNodes: Bool) async throws {
        let pageHTML = """
            <html lang="fr"><style>.away { display: none }</style><body>
            <section id="bulk" \(manyNodes ? "class='away'" : "hidden")></section>
            <div class="away"><p>CSS hidden</p></div><div style="opacity:0"><p>Transparent</p></div>
            <div style="content-visibility:hidden"><p>Skipped content</p></div>
            <div style="visibility:hidden">Invisible<span style="visibility:visible">Visible override</span></div>
            <details><summary>Summary</summary>Closed details</details>
            <section contenteditable="true">Editable</section><pre>Code</pre><div translate="no">Keep</div>
            <div id="host"><span slot="shown">Slotted</span><span slot="away">Hidden slot</span><b>Unassigned</b></div>
            <main style="display:contents">Visible article</main>
            <script>
            if (\(manyNodes)) {
                for (let i = 0; i < 3100; i++) bulk.append(document.createTextNode('Secret'));
            } else { bulk.textContent = 'X'.repeat(100000); }
            host.attachShadow({mode:'open'}).innerHTML =
                '<p>Shadow text</p><slot name="shown">Fallback</slot><div hidden><slot name="away"></slot></div><slot name="missing">Shown fallback</slot>';
            </script></body></html>
            """
        let fixture = PageToolFixture(pages: ["page": pageHTML])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("page"), page = try fixture.page(tab)
        try await fixture.waitUntil("language detected") { page.language != nil }
        var sent: [String] = []
        #expect(await fixture.manager.translatePage(tab.id) { texts in sent += texts; return texts.map { "[en] " + $0 } })
        #expect(sent == ["Visible override", "Summary", "Shadow text", "Slotted", "Shown fallback", "Visible article"])
        #expect(try await fixture.evaluate("document.querySelector('main').textContent", in: tab) as? String == "[en] Visible article")
    }

    @Test func translationTraversalStopsAtItsWorkLimitAndSkipsHiddenSubtrees() async throws {
        let pageHTML = """
            <div hidden id="hiddenTree"></div><div id="emptyTree"></div><main>Visible article</main>
            <script>
            hiddenTree.innerHTML = '<i></i>'.repeat(1000);
            emptyTree.innerHTML = '<i></i>'.repeat(80);
            </script>
            """
        let fixture = PageToolFixture(pages: ["page": pageHTML])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("page"), page = try fixture.page(tab)
        func collect(budget: Int) async throws -> [String]? {
            try await page.view.callAsyncJavaScript(WebViewManager.translationCollect,
                arguments: ["runID": "quota", "maxNodes": 10, "maxCharacters": 100, "maxVisited": budget],
                in: nil, contentWorld: WebViewManager.translationWorld) as? [String]
        }
        #expect(try await collect(budget: 40) == [])
        #expect(try await collect(budget: 110) == ["Visible article"])

        _ = try await fixture.evaluate("""
            for (let i = 0; i < 40; i++) document.querySelector('main').append(document.createTextNode('More text'));
            """, in: tab)
        let counts = try await page.view.callAsyncJavaScript("""
            const original = window.getComputedStyle, article = document.querySelector('main');
            let articleReads = 0, hiddenChildReads = 0;
            window.getComputedStyle = function(element) {
                if (element === article) articleReads++;
                if (element.parentElement?.id === 'hiddenTree') hiddenChildReads++;
                return original.call(window, element);
            };
            try {
                const texts = (() => { \(WebViewManager.translationCollect) })();
                return [texts.length, articleReads, hiddenChildReads];
            } finally { window.getComputedStyle = original; }
            """, arguments: ["runID": "style-count", "maxNodes": 100, "maxCharacters": 1_000, "maxVisited": 200],
            in: nil, contentWorld: WebViewManager.translationWorld)
        #expect(counts as? [Int] == [41, 1, 0])
    }

    @Test func thePageMenuOffersTranslateOnlyWithATitleFromTheWindow() async throws {
        let fixture = PageToolFixture(pages: ["french": Self.french])
        defer { fixture.cleanup() }
        let tab = try await stand(in: fixture)
        let manager = fixture.manager
        let view = try #require(manager.pages[tab.id]?.view as? BrowserWebView)
        #expect(!view.makeContextMenu(for: .init()).items.contains { $0.title.hasPrefix("Translate") })
        manager.translationMenuTitle = { $0 == tab.id ? "Translate to English" : nil }
        let menu = view.makeContextMenu(for: .init())
        let item = try #require(menu.items.first { $0.title == "Translate to English" })
        var requested: [UUID] = []
        manager.onTranslatePage = { requested.append($0) }
        menu.performActionForItem(at: menu.index(of: item))
        #expect(requested == [tab.id])
    }
}
