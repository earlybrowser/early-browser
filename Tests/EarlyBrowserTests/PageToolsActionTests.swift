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

        init(session: BrowserSession = BrowserSession(), history: HistoryStore? = nil) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyPageTools-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults, history: history)
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

    @Test func backAndForwardListsJumpWithinTheFocusedTabAndAClickStillNavigates() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let id = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(id)
        #expect(!model.canPerform(.goToHistory(offset: -1)))
        model.presentCommandBar(.navigateCurrentTab)
        model.updateQuery("early-test://fixture/two")
        #expect(model.submit())
        try await fixture.waitUntil("two") {
            model.webViews.pages[id]?.view.url == URL(string: "early-test://fixture/two") && model.webViews.pages[id]?.isLoading == false
        }
        #expect(model.canPerform(.goToHistory(offset: -1)) && !model.canPerform(.goToHistory(offset: -2)))
        #expect(!model.canPerform(.goToHistory(offset: 1)) && !model.canPerform(.goToHistory(offset: 0)))

        let view = HistoryMenuOverlay.HistoryMenuView()
        view.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        view.entries = { model.webViews.historyList(id, forward: false) }
        var selected: [Int] = [], clicks = 0
        view.onSelect = { selected.append($0) }
        view.onClick = { clicks += 1 }
        let menu = try #require(view.makeMenu())
        #expect(menu.items.map(\.title) == ["Page One"] && menu.items.map(\.tag) == [-1])
        menu.performActionForItem(at: 0)
        #expect(selected == [-1])
        view.entries = { [] }
        #expect(view.makeMenu() == nil, "No list, no menu")

        // A short click is an ordinary Back, not a menu.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }
        #expect(clicks == 1)
        #expect(!view.mouseDownCanMoveWindow, "Pressing Back never drags the window")
        view.cancelHold()
    }

    @Test func tabCleanupClosesTodayTabsAndReleasesTheirPages() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let urls = ["one", "two", "article"].map { URL(string: "early-test://fixture/\($0)")! }
        #expect(model.openLocations(urls))
        let today = model.todayTabs.map(\.id)
        #expect(today.count == 3 && model.webViews.liveViewCount == 3)
        #expect(model.perform(.selectTab(today[0])))
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(titles.contains("Close Other Tabs") && titles.contains("Close Tabs Below") && titles.contains("Clear Today Tabs"))
        #expect(model.perform(.closeTabsBelow(today[0])))
        #expect(model.todayTabs.map(\.id) == [today[0]] && model.webViews.liveViewCount == 1, "Closed pages are released")
        #expect(!model.canPerform(.closeOtherTabs(today[0])) && !model.canPerform(.closeTabsBelow(today[0])))
        #expect(model.perform(.reopenLastTab) && model.todayTabs.count == 2)
        #expect(model.perform(.clearTodayTabs) && model.todayTabs.isEmpty && !model.canPerform(.clearTodayTabs))
    }

    @Test func recentlyClosedListsTabsNewestFirstAndReopensAnyOfThem() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations(["one", "two", "article"].map { URL(string: "early-test://fixture/\($0)")! }))
        let today = model.todayTabs.map(\.id)
        model.closeTab(today[0])
        model.closeTab(today[1])
        #expect(model.recentlyClosedTabs.map(\.id) == [today[1], today[0]])
        #expect(model.perform(.reopenRecentlyClosedTab(today[0])))
        #expect(model.activeTab?.id == today[0] && model.recentlyClosedTabs.map(\.id) == [today[1]])
        #expect(!model.canPerform(.reopenRecentlyClosedTab(today[0])), "Reopened once")
        #expect(model.perform(.reopenLastTab) && model.recentlyClosedTabs.isEmpty)

        #expect(BrowserCommands.menuTitle(" Page\nOne ") == "Page One")
        let long = BrowserCommands.menuTitle(String(repeating: "a", count: 80))
        #expect(long.count == 60 && long.hasSuffix("…"), "Long titles stay short in menus")
    }

    @Test func historyMenuListsTodaysPagesOnceNewestFirstAndOpensThemAsTabs() async throws {
        let history = HistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite"))
        defer { Task { try? await history.removeFile() } }
        let fixture = Fixture(history: history)
        defer { fixture.cleanup() }
        let model = fixture.model
        let one = URL(string: "early-test://fixture/one")!, two = URL(string: "early-test://fixture/two")!
        #expect(model.recentlyVisited.isEmpty)
        for url in [one, two] {
            #expect(model.openLocations([url]))
            try await fixture.waitForLoad(model.coordinator.focusedTabID)
        }
        try await fixture.waitUntil("menu pages") {
            model.recentlyVisited.map(\.url) == [two, one] && model.recentlyVisited.first?.title == "Page Two"
        }

        // Opening one adds a Today tab and moves it to the top, listed once.
        let tabs = model.todayTabs.count
        #expect(model.canPerform(.openHistoryPage(one)))
        #expect(model.perform(.openHistoryPage(one)))
        #expect(model.todayTabs.count == tabs + 1 && model.activeTab?.currentURL == one)
        try await fixture.waitUntil("revisited") { model.recentlyVisited.map(\.url) == [one, two] }
        #expect(!model.canPerform(.openHistoryPage(URL(string: "javascript:alert(1)")!)))

        await model.clearHistory(.all)
        try await fixture.waitUntil("cleared") { model.recentlyVisited.isEmpty }
    }

    @Test func visitsAreRecordedAndTheCommandBarOffersHistoryButNotOpenTabsTwice() async throws {
        let history = HistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite"))
        defer { Task { try? await history.removeFile() } }
        let fixture = Fixture(history: history)
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let one = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(one)
        #expect(model.openLocations([URL(string: "early-test://fixture/two")!]))
        let two = try #require(model.coordinator.focusedTabID)
        try await fixture.waitForLoad(two)
        try await fixture.waitUntil("titles") { model.coordinator.tabStore.tab(id: two)?.title == "Page Two" }
        await model.flushHistory()
        let visits = try await history.visits()
        #expect(Set(visits.map(\.url.absoluteString)) == ["early-test://fixture/one", "early-test://fixture/two"])
        #expect(visits.count == 2, "A title arriving later is not another visit")
        #expect(try await history.search("page two", limit: 5).first?.title == "Page Two")

        // An open tab appears once as that tab; a closed page comes from history.
        model.closeTab(one)
        model.presentCommandBar(.newTab)
        model.updateQuery("page")
        try await fixture.waitUntil("history results") {
            !model.commandSearch.isRefreshing && !model.commandSearch.isLoadingProviders
                && model.visibleCommandResults.contains { $0.candidate.kind == .history }
        }
        let results = model.visibleCommandResults
        #expect(results.contains { $0.candidate.kind == .history && $0.candidate.detail == "early-test://fixture/one" })
        #expect(!results.contains { $0.candidate.kind == .history && $0.candidate.detail == "early-test://fixture/two" })
        #expect(results.contains { $0.candidate.kind == .openTab && $0.candidate.detail == "early-test://fixture/two" })
        let page = try #require(results.first { $0.candidate.kind == .history })
        #expect(model.commandResultBadge(for: page.candidate) == "History")
        #expect(model.perform(page, source: .commandBar))
        #expect(model.activeTab?.currentURL == URL(string: "early-test://fixture/one") && model.coordinator.commandBar == nil)
    }

    @Test func reopeningAFavoriteOrPinAtItsSavedAddressIsAVisit() async throws {
        let history = HistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite"))
        defer { Task { try? await history.removeFile() } }
        let profile = UUID(), space = UUID()
        let one = URL(string: "early-test://fixture/one")!, two = URL(string: "early-test://fixture/two")!
        // Closed saved pages already carry their saved address and page title.
        let favorite = BrowserTab(spaceID: space, profileID: profile, title: "Page One", currentURL: one,
                                  pinnedURL: one, isOpen: false, pinnedTitle: "Page One", isFavorite: true)
        let pin = BrowserTab(spaceID: space, profileID: profile, title: "Page Two", currentURL: two,
                             pinnedURL: two, isOpen: false, pinnedTitle: "Page Two")
        let fixture = Fixture(session: BrowserSession(profileID: profile, activeSpaceID: space, tabs: [favorite, pin]),
                              history: history)
        defer { fixture.cleanup() }
        let model = fixture.model
        for tab in [favorite, pin] {
            #expect(model.perform(.selectTab(tab.id)))
            try await fixture.waitForLoad(tab.id)
            try await Task.sleep(for: .milliseconds(100))
        }
        await model.flushHistory()
        #expect(Set(try await history.visits().map(\.url)) == [one, two], "Opening a saved page records a visit")

        // Closing the pin and opening it again later is another visit.
        model.closeTab(pin.id)
        #expect(model.perform(.selectTab(pin.id)))
        try await fixture.waitForLoad(pin.id)
        try await Task.sleep(for: .milliseconds(100))
        await model.flushHistory()
        #expect(try await history.visits().filter { $0.url == two }.count == 2)

        // In the command bar the saved pages appear as themselves, not as history.
        model.closeTab(pin.id)
        model.closeTab(favorite.id)
        model.presentCommandBar(.newTab)
        model.updateQuery("page")
        try await fixture.waitUntil("results") { !model.commandSearch.isRefreshing && !model.commandSearch.isLoadingProviders }
        #expect(!model.visibleCommandResults.contains { $0.candidate.kind == .history })
        #expect(model.visibleCommandResults.contains { $0.candidate.target == .tab(pin.id) })
        // Clearing history keeps the icons of every tab, pin and Favorite.
        #expect(Set(model.sidebarURLs).isSuperset(of: [one, two]))
    }

    @Test func historyOpensAsAWindowSheetGroupsVisitsByDayAndClearsARange() async throws {
        let withoutHistory = Fixture()
        #expect(!withoutHistory.model.canPerform(.showHistory), "No history store, no History")
        withoutHistory.cleanup()
        let history = HistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite"))
        defer { Task { try? await history.removeFile() } }
        let fixture = Fixture(history: history)
        defer { fixture.cleanup() }
        let model = fixture.model
        let now = Date()
        let old = URL(string: "https://example.com/old")!, recent = URL(string: "https://example.com/recent")!
        try await history.record(old, title: "Old", at: now.addingTimeInterval(-3 * 86400))
        try await history.record(recent, title: "Recent", at: now.addingTimeInterval(-60))

        #expect(model.canPerform(.showHistory) && model.perform(.showHistory) && model.historyPresented)
        #expect(!model.canPerform(.presentCommandBar(.newTab)), "History is modal for this window")
        model.historyPresented = false
        #expect(model.commandSearchCandidates().map(\.title).contains("Show All History"))
        #expect(model.perform(.clearHistory) && model.clearHistoryPresented)
        model.clearHistoryPresented = false

        let sections = HistoryView.sections(try await history.visits(), now: now)
        #expect(sections.map(\.title).first == "Today" && sections.count == 2)
        #expect(sections.first?.visits.map(\.url) == [recent])

        let revision = model.historyRevision
        await model.clearHistory(.lastHour)
        #expect(try await history.visits().map(\.url) == [old], "Only the chosen period is cleared")
        #expect(model.historyRevision == revision + 1)
        await model.clearHistory(.all)
        #expect(try await history.visits().isEmpty)
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
