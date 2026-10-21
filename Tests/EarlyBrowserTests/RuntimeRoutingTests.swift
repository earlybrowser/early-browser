// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
@testable import EarlyBrowser
import Testing
import WebKit

/// Local WebKit/controller integration only: no windows, input synthesis, or
/// UI automation. The actual split renderer remains a separate feature.
@Suite(.serialized) @MainActor
struct RuntimeRoutingTests {
    private let nextURL = URL(string: "early-test://fixture/two")!
    private let slowURL = URL(string: "early-test://fixture/slow")!

    @MainActor private final class Fixture {
        let suite = "local.early.tests.runtime.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel
        let pages: RoutingPages

        init(session: BrowserSession = BrowserSession()) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            defaults.set(false, forKey: "haptics")
            let pages = RoutingPages()
            self.pages = pages
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyRuntime-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults,
                configureWebView: { $0.setURLSchemeHandler(pages, forURLScheme: "early-test") })
        }

        func cleanup() {
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }

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

    @Test func restorationPreparesVisibleMembersAndPaneFocusReusesTheirLivePages() async throws {
        let session = splitSession(), fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model, first = session.tabs[0].id, second = session.tabs[1].id
        let group = try #require(model.coordinator.activeSplitGroup)
        let firstView = try #require(model.activePage?.view)
        let restoredSecondView = try #require(model.webViews.existingView(for: second))
        #expect(model.webViews.creationCount == 2)
        #expect(model.webViews.lifecycle(for: second).ownsView)
        #expect(model.webViews.visibleTabIDs == [first, second] && model.webViews.focusedTabID == first)

        #expect(model.focusPane(group.panes[1].id))
        let secondView = try #require(model.activePage?.view)
        #expect(secondView === restoredSecondView)
        #expect(model.coordinator.focusedTabID == second && model.webViews.creationCount == 2)
        #expect(model.perform(.selectTab(first)))
        #expect(model.activePage?.view === firstView)
        #expect(model.focusPane(group.panes[1].id))
        #expect(model.activePage?.view === secondView && model.webViews.creationCount == 2)
        let empty = try #require(model.createSpace(name: "Empty"))
        #expect(model.switchSpace(to: empty))
        #expect(model.activePage == nil && model.webViews.focusedTabID == nil && model.webViews.visibleTabIDs.isEmpty)
        #expect(model.webViews.creationCount == 2)
        #expect(!model.focusPane(group.panes[0].id), "A hidden Space cannot steal the current window's focus")
        #expect(model.switchSpace(to: session.activeSpaceID))
        #expect(model.activePage?.view === secondView && model.webViews.creationCount == 2)
        try await waitUntil { !firstView.isLoading && !secondView.isLoading }
    }

    @Test func addressHistoryReloadStopAndCloseRouteOnlyToTheFocusedPane() async throws {
        let session = splitSession(), fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model, first = session.tabs[0], second = session.tabs[1]
        let group = try #require(model.coordinator.activeSplitGroup)
        let firstPage = try #require(model.activePage)
        try await waitUntil("initial left page") { !firstPage.isLoading && firstPage.view.url == first.currentURL }
        _ = try await firstPage.view.evaluateJavaScript("window.paneMarker = 'untouched';")
        #expect(model.focusPane(group.panes[1].id))
        let secondPage = try #require(model.activePage)
        try await waitUntil("initial right page") { !secondPage.isLoading && secondPage.view.url == second.currentURL }

        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.coordinator.commandBar?.query == second.currentURL.absoluteString)
        model.updateQuery(nextURL.absoluteString)
        #expect(model.perform(.submit(), source: .commandBar))
        try await waitUntil("right navigation and history") {
            !secondPage.isLoading && !secondPage.view.isLoading && secondPage.view.url == nextURL
                && secondPage.view.title == "Page Two" && secondPage.canGoBack
        }
        #expect(model.coordinator.tabStore.tab(id: first.id)?.currentURL == first.currentURL)
        #expect(model.perform(.back))
        try await waitUntil("right back navigation") {
            !secondPage.isLoading && !secondPage.view.isLoading && secondPage.view.url == second.currentURL
                && secondPage.view.title == "Page One" && secondPage.canGoForward
        }
        #expect(model.perform(.forward))
        try await waitUntil("right forward navigation") {
            !secondPage.isLoading && !secondPage.view.isLoading && secondPage.view.url == nextURL
                && secondPage.view.title == "Page Two"
        }
        _ = try await secondPage.view.evaluateJavaScript("window.reloadMarker = true;")
        #expect(model.perform(.reload))
        try await waitUntil("right reload: url=\(String(describing: secondPage.view.url)), requested=\(secondPage.requestedURL), loading=\(secondPage.isLoading)/\(secondPage.view.isLoading), failure=\(secondPage.failure ?? "none"), lifecycle=\(model.webViews.lifecycle(for: second.id).state), focus=\(String(describing: model.coordinator.focusedTabID))") {
            !secondPage.isLoading && !secondPage.view.isLoading && secondPage.view.url == nextURL
        }
        #expect(try await secondPage.view.evaluateJavaScript("typeof window.reloadMarker") as? String == "undefined")
        #expect(try await firstPage.view.evaluateJavaScript("window.paneMarker") as? String == "untouched")
        #expect(model.webViews.creationCount == 2 && model.webViews.pages[first.id] === firstPage)

        // Both panes have pending loads. Stop must cancel only the focused one.
        model.webViews.load(slowURL, in: first)
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        model.updateQuery(slowURL.absoluteString)
        #expect(model.perform(.submit()))
        try await waitUntil("both pending loads") {
            fixture.pages.pendingCount == 2 && firstPage.view.isLoading && secondPage.view.isLoading
                && firstPage.view.url == slowURL && secondPage.view.url == slowURL
        }
        #expect(model.perform(.stop))
        try await waitUntil("right stop: native=\(secondPage.view.isLoading), url=\(String(describing: secondPage.view.url)), failure=\(secondPage.failure ?? "none"), lifecycle=\(model.webViews.lifecycle(for: second.id).state)") { !secondPage.isLoading }
        #expect(fixture.pages.pendingCount == 1, "Only the focused pane's request should be cancelled")
        #expect(firstPage.isLoading && model.webViews.lifecycle(for: first.id).state == .loading)
        #expect(model.perform(.closeActiveTab))
        #expect(model.coordinator.focusedTabID == first.id && model.activePage === firstPage)
        #expect(model.coordinator.splitGroups.isEmpty && model.webViews.liveViewCount == 1)
        #expect(secondPage.view.navigationDelegate == nil && secondPage.view.uiDelegate == nil)
    }

    @Test func favoritePromotionAndSelectionPreserveDOMStateAndClosedTilesReopenOnce() async throws {
        let profile = UUID(), space = UUID()
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Page One",
                             currentURL: URL(string: "early-test://fixture/one")!)
        let session = BrowserSession(profileID: profile, activeSpaceID: space, tabs: [tab],
                                     selectionBySpace: [space: tab.id])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        let page = try #require(model.activePage)
        try await waitUntil("favorite fixture") {
            !page.isLoading && !page.view.isLoading && page.view.title == "Page One"
        }
        _ = try await page.view.evaluateJavaScript("document.getElementById('saved').value = 'keep favorite state';")
        #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep favorite state")

        for action: BrowserAction in [.setFavorite(tab.id, true), .selectTab(tab.id),
                                      .setFavorite(tab.id, false), .setFavorite(tab.id, true), .selectTab(tab.id)] {
            #expect(model.perform(action))
            #expect(model.activePage === page && model.webViews.creationCount == 1)
            #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep favorite state")
        }

        #expect(model.perform(.closeTab(tab.id)))
        #expect(model.coordinator.tabStore.tab(id: tab.id)?.isOpen == false)
        #expect(model.webViews.liveViewCount == 0)
        // Changing a closed saved tile's section must not load or select it.
        #expect(model.perform(.setFavorite(tab.id, false)))
        #expect(model.perform(.setFavorite(tab.id, true)))
        #expect(model.activePage == nil && model.webViews.creationCount == 1)
        #expect(model.perform(.selectTab(tab.id)))
        let reopened = try #require(model.activePage)
        #expect(reopened !== page && model.webViews.creationCount == 2)
        try await waitUntil("reopened favorite fixture") {
            !reopened.isLoading && !reopened.view.isLoading && reopened.view.title == "Page One"
        }
        #expect(try await reopened.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "")
        #expect(model.perform(.selectTab(tab.id)))
        #expect(model.activePage === reopened && model.webViews.creationCount == 2)
        #expect(model.coordinator.tabStore.tabs.count == 1 && model.favorites.map(\.id) == [tab.id])
    }

    @Test(arguments: [false, true])
    func savedCommandBarNavigationPreservesDOMAndCurrentResultDoesNotResetDetours(favorite: Bool) async throws {
        let profile = UUID(), space = UUID()
        let url = URL(string: "early-test://fixture/one")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Page One", currentURL: url)
        let session = BrowserSession(profileID: profile, activeSpaceID: space, tabs: [tab],
                                     selectionBySpace: [space: tab.id])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model, page = try #require(model.activePage)
        try await waitUntil("saved command fixture") { !page.isLoading && page.view.title == "Page One" }
        #expect(model.perform(favorite ? .setFavorite(tab.id, true) : .setPinned(tab.id, true)))
        _ = try await page.view.evaluateJavaScript("document.getElementById('saved').value = 'keep saved page';")
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.performCommandBarSelection()) // Return on untouched prefill.
        #expect(model.webViews.creationCount == 1)
        #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep saved page")

        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        model.updateQuery(nextURL.absoluteString)
        #expect(model.performCommandBarSelection())
        let today = try #require(model.activeTab)
        #expect(today.id != tab.id && !today.isFavorite && today.pinnedURL == nil)
        #expect(model.webViews.pages[tab.id] === page && model.webViews.creationCount == 2)
        #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep saved page")
        #expect(model.coordinator.tabStore.tab(id: tab.id)?.currentURL == url)

        // Normal website navigation still belongs to this live saved page.
        #expect(model.perform(.selectTab(tab.id)))
        _ = try await page.view.evaluateJavaScript("document.querySelector('a').click();")
        try await waitUntil("saved page detour") { !page.isLoading && page.view.title == "Page Two" }
        #expect(model.coordinator.tabStore.tab(id: tab.id)?.currentURL == nextURL)
        #expect(model.coordinator.tabStore.tab(id: tab.id)?.pinnedURL == url)
        _ = try await page.view.evaluateJavaScript("document.getElementById('saved').value = 'keep detour';")
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        model.updateQuery(url.absoluteString) // Match its original saved address.
        try await waitUntil("current saved result") { !model.commandSearch.isRefreshing }
        let current = try #require(model.visibleCommandResults.first { $0.candidate.target == .tab(tab.id) })
        #expect(model.commandResultBadge(for: current.candidate) == "Current tab")
        #expect(model.perform(current))
        #expect(model.activePage === page && model.webViews.creationCount == 2 && page.view.url == nextURL)
        #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep detour")
    }

    @Test func tabSwitcherPreviewCancelAndCommitKeepExistingDOMAndSplitIdentity() async throws {
        let session = splitSession(), fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model, first = session.tabs[0].id, second = session.tabs[1].id
        let firstPage = try #require(model.webViews.pages[first])
        let secondPage = try #require(model.webViews.pages[second])
        try await waitUntil("switcher documents") {
            !firstPage.isLoading && !secondPage.isLoading
                && firstPage.view.title == "Page One" && secondPage.view.title == "Page One"
        }
        _ = try await firstPage.view.evaluateJavaScript("document.getElementById('saved').value = 'keep switcher state';")
        for _ in 0..<5 {
            #expect(model.advanceTabSwitcher(1, commitsOnControlRelease: true))
            #expect(model.coordinator.focusedTabID == first && model.activePage === firstPage)
            #expect(try await firstPage.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep switcher state")
            model.cancelTabSwitcher()
        }
        #expect(model.advanceTabSwitcher(1))
        #expect(model.commitTabSwitcher(selecting: second))
        #expect(model.coordinator.focusedTabID == second && model.activePage === secondPage)
        #expect(model.coordinator.splitGroups == session.splitGroups && model.webViews.creationCount == 2)
        #expect(model.advanceTabSwitcher(-1))
        #expect(model.commitTabSwitcher(selecting: first))
        #expect(model.activePage === firstPage && model.webViews.creationCount == 2)
        #expect(try await firstPage.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep switcher state")
    }

    @Test func windowLocalPaneFocusDoesNotShareLiveViewsOrSelection() throws {
        let session = splitSession(), first = Fixture(session: session), second = Fixture(session: session)
        defer { first.cleanup(); second.cleanup() }
        let group = try #require(first.model.coordinator.activeSplitGroup)
        let firstView = try #require(first.model.activePage?.view)
        #expect(second.model.focusPane(group.panes[1].id))
        #expect(first.model.coordinator.focusedTabID == session.tabs[0].id)
        #expect(second.model.coordinator.focusedTabID == session.tabs[1].id)
        #expect(second.model.webViews.existingView(for: session.tabs[0].id) !== firstView)
        #expect(first.model.webViews.creationCount == 2 && second.model.webViews.creationCount == 2)
    }

    @Test func paneFocusUsesTheSharedEditorAndDialogAvailabilityRules() throws {
        let session = splitSession(), fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        let group = try #require(model.coordinator.activeSplitGroup)
        let page = try #require(model.activePage)
        let otherPage = try #require(model.webViews.pages[session.tabs[1].id])
        let before = model.coordinator.session, focusRequest = model.contentFocusRequest
        model.folderEditorIsPresented = true
        #expect(!model.focusPane(group.panes[1].id))
        model.folderEditorIsPresented = false
        page.hasDialog = true // Availability only; no native sheet is presented.
        #expect(!model.focusPane(group.panes[1].id))
        page.hasDialog = false
        #expect(model.coordinator.session == before && model.contentFocusRequest == focusRequest)
        #expect(model.webViews.creationCount == 2 && model.webViews.pages[session.tabs[1].id] === otherPage)
        #expect(model.focusPane(group.panes[1].id))
        #expect(model.coordinator.focusedTabID == session.tabs[1].id)
    }

    @Test func emptyAndUnselectedSessionsKeepZeroViewsThroughCommandBarAndLastTabClose() throws {
        var session = splitSession()
        session.selectionBySpace = [:]
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.activePage == nil && model.webViews.creationCount == 0)
        for intent: CommandBarIntent in [.newTab, .navigateCurrentTab] {
            #expect(model.perform(.presentCommandBar(intent)))
            model.updateQuery("not submitted")
            #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
        }
        #expect(model.webViews.creationCount == 0 && model.webViews.liveViewCount == 0)
        for tab in session.tabs { #expect(model.perform(.closeTab(tab.id))) }
        #expect(model.coordinator.content == .empty && model.coordinator.commandBar == nil)
        #expect(model.webViews.liveViewCount == 0 && model.webViews.lifecycles.isEmpty)
    }

    @Test func pageHostsCannotStealOneViewOrReattachAfterDismantling() throws {
        let fixture = Fixture(session: splitSession())
        let first = WebContentView.HostView(), second = WebContentView.HostView()
        defer { first.invalidate(); second.invalidate(); fixture.cleanup() }
        let view = try #require(fixture.model.activePage?.view)
        #expect(first.display(view))
        #expect(!second.display(view))
        #expect(view.superview === first && first.hosted === view && second.hosted == nil)
        #expect(first.display(nil))
        #expect(second.display(view))
        second.invalidate()
        #expect(view.superview == nil && second.hosted == nil)
        #expect(!second.display(view))
        #expect(first.display(view))
        #expect(fixture.model.webViews.creationCount == 2)
    }

    private func waitUntil(_ description: @autoclosure () -> String = "page loading", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout(description()) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum Failure: Error { case timeout(String) }
}

@MainActor private final class RoutingPages: NSObject, WKURLSchemeHandler {
    private var pending: Set<ObjectIdentifier> = []
    var pendingCount: Int { pending.count }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/slow" {
            pending.insert(ObjectIdentifier(task))
            return
        }
        let title = url.path == "/two" ? "Page Two" : "Page One"
        let data = Data("<!doctype html><title>\(title)</title><p>Local routing fixture</p><input id='saved' aria-label='Saved text'><a href='early-test://fixture/two'>Go to Two</a>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        pending.remove(ObjectIdentifier(task))
    }
}
