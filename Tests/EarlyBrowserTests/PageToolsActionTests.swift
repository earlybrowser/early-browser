// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing

/// Window-level find, zoom, Reader, translation and Paste and Go commands with
/// local fixture pages, unshown windows and no UI automation.
@Suite(.serialized) @MainActor
struct PageToolsActionTests {
    @MainActor private final class Fixture {
        let suite = "local.early.tests.pagetools.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel

        init(session: BrowserSession = BrowserSession()) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyPageTools-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults)
        }

        func cleanup() {
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }

        func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func waitForLoad(_ id: UUID?) async throws {
            try await waitUntil("load") {
                guard let id, let page = model.webViews.pages[id] else { return false }
                return page.view.url != nil && !page.isLoading && !page.view.isLoading
            }
        }
    }

    private enum Failure: Error { case timeout(String) }

    private func splitSession() -> BrowserSession {
        let profile = UUID(), space = UUID()
        let tabs = ["left", "right"].map { side in
            BrowserTab(spaceID: space, profileID: profile, title: side,
                       currentURL: URL(string: "early-test://fixture/one?pane=\(side)")!)
        }
        let group = BrowserSplitGroup(spaceID: space, panes: tabs.map { BrowserSplitPane(tabID: $0.id) })
        return BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs,
            selectionBySpace: [space: tabs[0].id], splitGroups: [group],
            focusedPaneByGroupID: [group.id: group.panes[0].id])
    }

    @Test func zoomCommandsTargetTheFocusedPaneAndConfirmTheLevel() async throws {
        let fixture = Fixture(session: splitSession())
        defer { fixture.cleanup() }
        let model = fixture.model
        let group = try #require(model.coordinator.activeSplitGroup)
        let left = group.panes[0].tabID, right = group.panes[1].tabID
        try await fixture.waitForLoad(left)
        try await fixture.waitForLoad(right)
        #expect(!model.canPerform(.resetZoom) && model.canPerform(.zoomIn))
        #expect(model.perform(.focusSplitPane(group.panes[1].id)))
        #expect(model.perform(.zoomIn) && model.perform(.zoomIn))
        #expect(model.webViews.pages[right]?.zoom == 1.25 && model.webViews.pages[left]?.zoom == 1)
        #expect(model.zoomNotice?.tabID == right && model.zoomNotice?.zoom == 1.25)
        #expect(ZoomNoticeView.text(for: 1.25) == "125%" && ZoomNoticeView.text(for: 0.85) == "85%")
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(titles.contains("Zoom In") && titles.contains("Zoom Out") && titles.contains("Actual Size"))
        #expect(model.perform(.resetZoom) && model.webViews.pages[right]?.zoom == 1)
        #expect(!model.commandSearchCandidates().map(\.title).contains("Actual Size"), "Only working commands are offered")

        #expect(PageShortcutMonitor.isZoomIn(characters: "=", modifiers: .command))
        #expect(!PageShortcutMonitor.isZoomIn(characters: "=", modifiers: [.command, .option]))
        #expect(!PageShortcutMonitor.isZoomIn(characters: "=", modifiers: []), "Typing = in a page is never taken")
        #expect(!PageShortcutMonitor.isZoomIn(characters: "-", modifiers: .command))
    }

    @Test func pasteAndGoReadsTheClipboardOnlyWhenChosenAndFollowsTypedRules() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        // A private pasteboard: tests never read or replace the user's clipboard.
        let pasteboard = NSPasteboard(name: .init("local.early.tests.paste.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        model.refreshPasteKind(pasteboard)
        #expect(model.pasteKind == nil, "No text, no item")
        // An empty window starts with the New Tab command bar; nothing changes it.
        let initial = model.coordinator.commandBar
        #expect(!model.pasteAndGo(.newTab, pasteboard: pasteboard))
        #expect(model.coordinator.commandBar == initial)

        pasteboard.clearContents()
        pasteboard.setString("early-test://fixture/\ntwo", forType: .string)
        model.refreshPasteKind(pasteboard)
        #expect(model.pasteKind != nil)
        #expect(model.pasteKind(for: "early-test://fixture/two") == .address)
        #expect(model.pasteKind(for: "best pasta recipe") == .search)
        #expect(PageToolsActionTests.titles == ["Paste and Go", "Paste and Search"])

        #expect(model.pasteAndGo(.newTab, pasteboard: pasteboard))
        #expect(model.coordinator.commandBar == nil && model.todayTabs.count == 1)
        #expect(model.activeTab?.currentURL == URL(string: "early-test://fixture/two"), "The wrapped address was joined")

        pasteboard.clearContents()
        pasteboard.setString("javascript:alert(1)", forType: .string)
        #expect(!model.pasteAndGo(.newTab, pasteboard: pasteboard))
        #expect(model.coordinator.commandBar?.query == "javascript:alert(1)" && model.submissionMessage != nil,
                "A refused address stays in the bar with its message, as if typed")
        #expect(model.todayTabs.count == 1)
        model.dismissCommandBar()

        // The command bar's own menu offers it after Paste, and only with a title.
        let control = CommandBarInputControl()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        control.pasteAndGoTitle = { "Paste and Go" }
        control.addPasteAndGo(to: menu)
        control.addPasteAndGo(to: menu)
        #expect(menu.items.map(\.title) == ["Cut", "Paste", "Paste and Go"], "Inserted once, after Paste")
        control.pasteAndGoTitle = { nil }
        control.addPasteAndGo(to: menu)
        #expect(menu.items.map(\.title) == ["Cut", "Paste"])
        control.invalidate()
    }

    private static let titles = [BrowserWindowModel.PasteKind.address.title, BrowserWindowModel.PasteKind.search.title]

    @Test func readerIsOfferedForArticlesAndFocusMovesIntoReaderAndBack() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let plain = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(plain)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.canPerform(.toggleReader), "A page that is not an article has no Reader")
        #expect(SiteControlsButton.isVisible(for: model) && !SiteControlsButton.isActive(model.activePage))

        #expect(model.openLocations([URL(string: "early-test://fixture/article")!]))
        let id = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(id)
        try await fixture.waitUntil("article") { model.webViews.pages[id]?.isReaderAvailable == true }
        #expect(model.canPerform(.toggleReader))
        let page = try #require(model.webViews.pages[id])
        #expect(SiteControlsPanel.readerValue(page) == "Off")
        #expect(model.commandSearchCandidates().map(\.title).contains("Show Reader"))
        let focus = model.contentFocusRequest
        #expect(model.perform(.toggleReader))
        try await fixture.waitUntil("reader") { model.webViews.pages[id]?.isReaderShown == true }
        #expect(model.contentFocusRequest == focus + 1, "Focus moves into Reader")
        #expect(model.webViews.readerView(for: id) != nil)
        #expect(SiteControlsButton.isActive(page) && SiteControlsPanel.readerValue(page) == "On",
                "The site controls icon takes the theme color while Reader is on")
        #expect(model.commandSearchCandidates().map(\.title).contains("Hide Reader"))
        #expect(model.readerAccent.light.hasPrefix("#") && model.readerAccent.light.count == 7)

        #expect(model.perform(.toggleReader))
        #expect(model.webViews.pages[id]?.isReaderShown == false && model.contentFocusRequest == focus + 2)
        #expect(model.webViews.readerView(for: id) == nil)
    }

    @Test func translateIsOfferedOnlyForAnotherLanguageAndTogglesBackToTheOriginal() async throws {
        #expect(BrowserWindowModel.needsTranslation(from: "fr", to: "en"))
        #expect(!BrowserWindowModel.needsTranslation(from: "en-GB", to: "en"))
        #expect(!BrowserWindowModel.needsTranslation(from: "zh-Hant", to: "zh"))
        #expect(TranslationBadge.message(for: .original, pending: false, sourceName: "French") == nil)
        #expect(TranslationBadge.message(for: .original, pending: true, sourceName: "French") == "Translating…")
        #expect(TranslationBadge.message(for: .translated, pending: false, sourceName: "French") == "Translated from French")
        #expect(TranslationBadge.message(for: .failed("x"), pending: false, sourceName: nil) == "Couldn’t translate this page")

        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations([URL(string: "early-test://fixture/article?lang=fr")!]))
        let id = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(id)
        try await fixture.waitUntil("language") { model.webViews.pages[id]?.language == "fr" }
        // Apple's language support varies by Mac; stand in for its answer.
        model.translationOffers[id] = TranslationOffer(tabID: id, source: "fr", target: "en")
        let title = "Translate to \(TranslationOffer.name("en"))"
        #expect(model.translationTitle(for: id) == title && model.canPerform(.toggleTranslation))
        #expect(model.commandSearchCandidates().map(\.title).contains(title))
        #expect(model.webViews.translationMenuTitle?(id) == title, "The page menu uses the same title")

        let page = try #require(model.webViews.pages[id])
        #expect(SiteControlsPanel.translationValue(page, title: title) == "To \(TranslationOffer.name("en"))")
        #expect(model.perform(.toggleTranslation))
        #expect(model.translationRequest?.offer.tabID == id && model.translationTitle(for: id) == "Show Original")
        #expect(model.perform(.toggleTranslation))
        #expect(model.translationRequest == nil && model.translationTitle(for: id) == title)

        // Reader shows the article instead, so Translate waits until it closes.
        try await fixture.waitUntil("article") { model.webViews.pages[id]?.isReaderAvailable == true }
        model.toggleReader(id)
        try await fixture.waitUntil("reader") { model.webViews.pages[id]?.isReaderShown == true }
        #expect(model.translationTitle(for: id) == nil && !model.canPerform(.toggleTranslation))
    }

    @Test func findOpensForTheFocusedPaneOnlyAndClosingReturnsFocusToThePage() async throws {
        let fixture = Fixture(session: splitSession())
        defer { fixture.cleanup() }
        let model = fixture.model
        let group = try #require(model.coordinator.activeSplitGroup)
        let left = group.panes[0].tabID, right = group.panes[1].tabID
        try await fixture.waitForLoad(left)
        try await fixture.waitForLoad(right)
        #expect(model.canPerform(.find) && !model.canPerform(.findNext), "Nothing to repeat yet")
        #expect(model.perform(.focusSplitPane(group.panes[1].id)))
        let request = model.findFocusRequest
        #expect(model.perform(.find))
        #expect(model.webViews.pages[right]?.find != nil && model.webViews.pages[left]?.find == nil)
        #expect(model.findFocusRequest == request + 1)
        model.webViews.updateFind(right, query: "page one")
        try await fixture.waitUntil("search") { model.webViews.pages[right]?.find?.isSearching == false }
        let state = try #require(model.webViews.pages[right]?.find)
        #expect(state.matchCount == 1 && PageFindBar.status(for: state) == "1 of 1")
        #expect(model.canPerform(.findNext) && model.perform(.findPrevious))
        #expect(model.commandSearchCandidates().map(\.title).contains("Find on Page…"))

        let focus = model.contentFocusRequest
        model.closeFind(right)
        #expect(model.webViews.pages[right]?.find == nil && model.contentFocusRequest == focus + 1)

        // Use Selection for Find takes the page's selected text.
        #expect(model.perform(.focusSplitPane(group.panes[0].id)))
        _ = try await model.webViews.pages[left]?.view.evaluateJavaScript("""
            const range = document.createRange(); range.selectNodeContents(document.querySelector('h1'));
            getSelection().removeAllRanges(); getSelection().addRange(range); true
            """)
        #expect(model.perform(.useSelectionForFind))
        try await fixture.waitUntil("selection") {
            model.webViews.pages[left]?.find?.query == "Page One" && model.webViews.pages[left]?.find?.isSearching == false
        }
        #expect(model.webViews.pages[left]?.find?.matchCount == 1)

        var empty = PageFindState(query: "")
        #expect(PageFindBar.status(for: empty).isEmpty)
        empty.query = "missing"
        #expect(PageFindBar.status(for: empty) == "No matches")
        empty.isSearching = true
        #expect(PageFindBar.status(for: empty).isEmpty, "No verdict while the search runs")
        var many = PageFindState(query: "word")
        many.matchCount = PageFindState.matchLimit
        many.currentIndex = 2
        many.isCapped = true
        #expect(PageFindBar.status(for: many) == "3 of 1000+")
    }
}
