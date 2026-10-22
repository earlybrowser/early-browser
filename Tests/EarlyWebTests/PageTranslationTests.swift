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
