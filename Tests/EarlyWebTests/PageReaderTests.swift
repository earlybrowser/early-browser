// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Reader Mode with Mozilla Readability against local article fixtures.
@Suite(.serialized) @MainActor
struct PageReaderTests {
    static let paragraph = "Early keeps the browser quiet so the page can speak. Spaces gather the tabs for one "
        + "project, pinned pages stay where you left them, and the sidebar folds away when you want the whole "
        + "window. Reading should feel the same: plain type, steady margins and nothing moving at the edges. "
        + "This paragraph repeats so the fixture reads like a real article with enough words to extract."

    static let article = """
        <!doctype html><html lang="en"><head><title>Quiet Browsing | Early Journal</title>
        <meta property="og:site_name" content="Early Journal"></head>
        <body><nav><a href="/">Home</a> <a href="/about">About</a></nav>
        <article><h1>Quiet Browsing</h1><p class="byline">By Ada Example</p>
        <p>\(paragraph)</p><p onclick="alert(1)">\(paragraph) <a href="javascript:alert(2)">Unsafe</a></p>
        <p>\(paragraph) <a id="next" href="/next">Next part</a> and <a href="#notes">notes</a>.</p>
        <iframe src="/embed"></iframe><script>window.early = 'page script';</script>
        <form action="/submit"><input name="q"><button>Send</button></form>
        <p style="color:red">\(paragraph)</p><h2 id="notes">Notes</h2><p>\(paragraph)</p></article>
        <footer>Footer links</footer></body></html>
        """

    private func readerFixture() async throws -> (PageToolFixture, BrowserTab) {
        let fixture = PageToolFixture(pages: ["article": Self.article, "short": "<p>Only a line.</p>",
                                              "next": "<p>Next page</p>"])
        let tab = try await fixture.open("article")
        try await fixture.waitUntil("readerable") { fixture.manager.pages[tab.id]?.isReaderAvailable == true }
        return (fixture, tab)
    }

    private let accent = ReaderAccent(light: "#aa3300", dark: "#ff8844")

    @Test func articlesAreOfferedAndShownCleanedWhileShortPagesAreNot() async throws {
        let (fixture, tab) = try await readerFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let short = try await fixture.open("short")
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.pages[short.id]?.isReaderAvailable == false && !manager.canToggleReader(short.id))
        #expect(await !manager.showReader(short.id, accent: accent), "A page that is not an article has no Reader")

        #expect(manager.canToggleReader(tab.id))
        #expect(await manager.showReader(tab.id, accent: accent))
        let page = try fixture.page(tab)
        let article = try #require(page.readerArticle)
        // Readability keeps "| Early Journal" when the short title would be too short.
        #expect(page.isReaderShown && article.title.hasPrefix("Quiet Browsing") && article.byline == "By Ada Example")
        #expect(article.siteName == "Early Journal" && article.language == "en" && article.readingMinutes >= 1)
        for removed in ["<script", "<iframe", "<form", "<input", "<button", "onclick", "javascript:", "style="] {
            #expect(!article.content.contains(removed), "\(removed) is removed from the article")
        }
        #expect(article.content.contains("href=\"early-tools://fixture/next\""), "Links are kept and made absolute")
        #expect(!article.content.contains("Footer links") && !article.content.contains("About"))

        let reader = try #require(manager.readerView(for: tab.id))
        // The color behind Reader matches its page, so no other page's color
        // shows through the pane's rounded corners.
        for (name, expected) in [(NSAppearance.Name.darkAqua, 0x1b), (.aqua, 0xfb)] {
            reader.appearance = NSAppearance(named: name)
            let red = reader.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? -1
            #expect(Int((red * 255).rounded()) == expected, "\(name.rawValue)")
        }
        reader.appearance = nil
        #expect(reader.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(reader.configuration.websiteDataStore === manager.websiteDataStore, "Reader stays in the profile")
        try await fixture.waitUntil("reader load") { !reader.isLoading && reader.url != nil }
        let html = try await reader.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        #expect(html.contains("Content-Security-Policy") && html.contains("#aa3300") && html.contains("Quiet Browsing"))
        // The original page is untouched by extraction.
        #expect(try await fixture.evaluate("document.querySelectorAll('script, iframe, form').length", in: tab) as? Int == 3)
        #expect(try await fixture.evaluate("typeof Readability", in: tab) as? String == "undefined")
    }

    @Test func readerSharesZoomAndFindAndLinksOrNavigationReturnToThePage() async throws {
        let (fixture, tab) = try await readerFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        #expect(manager.zoom(tab.id, by: 1))
        #expect(await manager.showReader(tab.id, accent: accent))
        let reader = try #require(manager.readerView(for: tab.id) as? ReaderWebView)
        #expect(reader.pageZoom == 1.15)
        #expect(manager.zoom(tab.id, by: 1) && reader.pageZoom == 1.25, "Zoom sizes Reader's text too")
        try await fixture.waitUntil("reader load") { !reader.isLoading && reader.url != nil }

        // Find searches what is being read: the article, not the page's menus.
        manager.showFind(tab.id)
        manager.updateFind(tab.id, query: "Footer links")
        try await fixture.waitUntil("find") { manager.pages[tab.id]?.find?.isSearching == false }
        #expect(manager.pages[tab.id]?.find?.matchCount == 0)
        manager.updateFind(tab.id, query: "Quiet Browsing")
        try await fixture.waitUntil("find title") { manager.pages[tab.id]?.find?.isSearching == false }
        #expect(manager.pages[tab.id]?.find?.matchCount == 1)

        // A table-of-contents jump stays; other links leave Reader for the page.
        let document = try #require(reader.documentURL)
        #expect(ReaderWebView.sameDocument(URL(string: document.absoluteString + "#notes")!, document))
        #expect(!ReaderWebView.sameDocument(fixture.url("next"), document))
        manager.openReaderLink(URL(string: "javascript:alert(1)")!, from: tab.id, newTab: false)
        #expect(manager.pages[tab.id]?.isReaderShown == true, "Unsafe links do nothing")
        var opened: [URL] = []
        manager.onOpenBackgroundLink = { opened.append($0) }
        manager.openReaderLink(URL(string: "https://example.com/elsewhere")!, from: tab.id, newTab: true)
        #expect(opened == [URL(string: "https://example.com/elsewhere")!] && manager.pages[tab.id]?.isReaderShown == true)

        manager.load(fixture.url("next"), in: tab)
        try await fixture.waitUntil("navigate") {
            manager.pages[tab.id]?.view.url == fixture.url("next") && manager.pages[tab.id]?.isLoading == false
        }
        #expect(manager.pages[tab.id]?.isReaderShown == false && manager.readerView(for: tab.id) == nil,
                "A new document returns to the page")
        try await fixture.waitUntil("not readerable") { manager.pages[tab.id]?.isLoading == false }
        #expect(manager.pages[tab.id]?.find == nil || manager.pages[tab.id]?.find?.matchCount == 0)
    }

    @Test func escapeAndClosingTheTabLeaveReaderAndOnlyWorkingMenuItemsRemain() async throws {
        let (fixture, tab) = try await readerFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        #expect(await manager.showReader(tab.id, accent: accent))
        let reader = try #require(manager.readerView(for: tab.id) as? ReaderWebView)

        let menu = NSMenu()
        for identifier in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierDownloadLinkedFile",
                           "separator", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb", "separator",
                           "WKMenuItemIdentifierReload", "separator"] {
            if identifier == "separator" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
        }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        reader.willOpenMenu(menu, with: event)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            == ["WKMenuItemIdentifierCopy", "—", "WKMenuItemIdentifierLookUp"])

        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        reader.keyDown(with: escape)
        #expect(manager.pages[tab.id]?.isReaderShown == false && manager.readerView(for: tab.id) == nil)

        #expect(await manager.showReader(tab.id, accent: accent))
        manager.reconcile(tabs: [])
        #expect(manager.readerView(for: tab.id) == nil, "Closing the tab releases Reader")
    }

    @Test func documentTemplateEscapesTextAndRejectsInvalidAccents() throws {
        let article = try #require(ReaderArticle(["title": "<script>x</script>", "byline": "A & B",
            "content": "<p>Body</p>", "words": 460, "lang": "fr", "dir": "rtl"]))
        let html = ReaderDocument.html(article, accent: ReaderAccent(light: "red;}</style>", dark: "#123456"))
        #expect(html.contains("&lt;script&gt;x&lt;/script&gt;") && !html.contains("<script>x"))
        #expect(html.contains("A &amp; B · 2 min read") && html.contains("lang=\"fr\" dir=\"rtl\""))
        #expect(!html.contains("red;}") && html.contains("#3a6fb0") && html.contains("#123456"))
        #expect(ReaderArticle(["content": ""]) == nil && ReaderArticle(nil) == nil)
    }
}
