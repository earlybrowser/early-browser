// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct BrowserCoordinatorTests {
    private let space = UUID()
    private let profile = UUID()

    @Test func pinDetourRequiresAnOpenPinAtADifferentFullURL() {
        var pin = tab(pinned: true)
        let original = pin.currentURL
        #expect(!pin.hasNavigatedFromPin)
        for address in ["https://example.com/video", "https://example.com?q=video", "https://example.com#video"] {
            pin.currentURL = URL(string: address)!
            #expect(pin.hasNavigatedFromPin)
        }
        pin.isOpen = false
        #expect(!pin.hasNavigatedFromPin)
        pin.isOpen = true
        pin.currentURL = original
        #expect(!pin.hasNavigatedFromPin)
        pin.pinnedURL = nil
        pin.currentURL = URL(string: "https://example.com/video")!
        #expect(!pin.hasNavigatedFromPin)
    }

    private func tab(pinned: Bool = false, in spaceID: UUID? = nil) -> BrowserTab {
        let url = URL(string: "https://example.com")!
        return BrowserTab(
            spaceID: spaceID ?? space, profileID: profile,
            title: "Example", currentURL: url, pinnedURL: pinned ? url : nil
        )
    }

    private func coordinator(tabs: [BrowserTab], selected: UUID?) -> BrowserCoordinator {
        BrowserCoordinator(
            startup: .returningSession, activeSpaceID: space,
            tabStore: TabStore(tabs: tabs),
            selectionBySpace: selected.map { [space: $0] } ?? [:], profileID: profile
        )
    }

    @Test func freshLaunchShowsBarWithoutTab() {
        let browser = BrowserCoordinator(startup: .firstLaunch)
        #expect(browser.content == .empty)
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.commandBar?.intent == .newTab)
        browser.dismissCommandBar()
        #expect(browser.commandBar == nil)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test func returningEmptySessionStaysEmpty() {
        let browser = BrowserCoordinator(startup: .returningSession)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test(arguments: [CommandBarIntent.newTab, .navigateCurrentTab])
    func openingAndCancellingDoesNotCreateTab(intent: CommandBarIntent) {
        let browser = BrowserCoordinator(startup: .returningSession)
        browser.presentCommandBar(intent)
        browser.updateQuery("example.com")
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.navigationRequest()?.target == .newTab(spaceID: browser.activeSpaceID))
        browser.dismissCommandBar()
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.content == .empty)
    }

    @Test func newTabCancellationPreservesExistingSelection() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: existing.id)
        let before = browser.tabStore
        browser.presentCommandBar(.newTab)
        browser.updateQuery("another.example")
        #expect(browser.navigationRequest()?.target == .newTab(spaceID: space))
        browser.dismissCommandBar()
        #expect(browser.tabStore == before)
        #expect(browser.content == .web(tabID: existing.id))
    }

    @Test func locationIntentTargetsCurrentTab() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: existing.id)
        browser.presentCommandBar(.navigateCurrentTab)
        #expect(browser.commandBar?.query == existing.currentURL.absoluteString)
        browser.updateQuery("  https://swift.org  ")
        #expect(browser.navigationRequest()?.query == "https://swift.org")
        #expect(browser.navigationRequest()?.target == .currentTab(existing.id))
        #expect(browser.tabStore.tabs == [existing])
    }

    @Test func blankSubmissionAndCommandSearchCannotCreateNavigation() {
        let browser = BrowserCoordinator(startup: .firstLaunch)
        browser.updateQuery(" \n ")
        #expect(browser.navigationRequest() == nil)
        browser.presentCommandBar(.commandSearch)
        browser.updateQuery("Close Tab")
        #expect(browser.navigationRequest() == nil)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test func closingSelectsNextThenPreviousNeighbor() {
        let first = tab()
        let second = tab()
        let third = tab()
        let browser = coordinator(tabs: [first, second, third], selected: second.id)
        #expect(browser.closeActiveTab() == second.id)
        #expect(browser.content == .web(tabID: third.id))
        browser.closeActiveTab()
        #expect(browser.content == .web(tabID: first.id))
        #expect(browser.tabStore.tabs == [first])
    }

    @Test func closingLastTabClosesBarAndLeavesEmptyWindow() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: existing.id)
        browser.presentCommandBar(.newTab)
        browser.closeActiveTab()
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        #expect(browser.closeActiveTab() == nil)
        browser.presentCommandBar(.newTab)
        #expect(browser.commandBar != nil)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test func closeInEmptyWindowIsNoOpEvenWithBarOpen() {
        let browser = BrowserCoordinator(startup: .firstLaunch)
        let before = browser.commandBar
        #expect(browser.closeActiveTab() == nil)
        #expect(browser.commandBar == before)
        #expect(browser.content == .empty)
    }

    @Test func closingPinRetainsIdentityAndResetsURL() {
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/article")!
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.closeActiveTab()
        let stored = browser.tabStore.tab(id: pin.id)
        #expect(stored?.isOpen == false)
        #expect(stored?.pinnedURL == pin.pinnedURL)
        #expect(stored?.currentURL == pin.pinnedURL)
        #expect(stored?.title == "Example")
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        browser.selectOpenTab(pin.id)
        #expect(browser.content == .empty)
    }

    @Test func emptySpaceDoesNotManufactureSelectionAndReturningRestoresIt() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: existing.id)
        browser.presentCommandBar(.navigateCurrentTab)
        let empty = browser.createSpace(name: "Empty")!
        browser.switchSpace(to: empty)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        browser.selectOpenTab(existing.id)
        #expect(browser.content == .empty)
        browser.switchSpace(to: space)
        #expect(browser.content == .web(tabID: existing.id))
    }

    @Test func closingDoesNotSelectTabsInOtherSpacesOrClosedPins() {
        let existing = tab()
        let otherSpace = tab(in: UUID())
        var closedPin = tab(pinned: true)
        closedPin.isOpen = false
        let browser = coordinator(tabs: [existing, otherSpace, closedPin], selected: existing.id)
        browser.closeActiveTab()
        #expect(browser.content == .empty)
        #expect(browser.tabStore.tabs.count == 2)
    }

    @Test func invalidRestoredSelectionIsEmpty() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: UUID())
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
    }

    @Test func repeatedInvocationRequestsFocusWithoutCreatingTabs() {
        let browser = BrowserCoordinator(startup: .returningSession)
        browser.presentCommandBar(.newTab)
        let firstRequest = browser.commandBarFocusRequest
        browser.presentCommandBar(.newTab)
        #expect(browser.commandBarFocusRequest == firstRequest + 1)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test func firstUseIsPersistedIndependentlyOfTabCount() throws {
        let suite = "local.early.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FirstLaunchStore(defaults: defaults)
        #expect(first.claimStartupContext() == .firstLaunch)
        // A new store represents a subsequent window/process using the same domain.
        let returning = FirstLaunchStore(defaults: defaults)
        #expect(returning.claimStartupContext() == .returningSession)
    }

    @Test func tabMetadataRoundTripsWithoutRuntimeObjects() throws {
        let pin = tab(pinned: true)
        let data = try JSONEncoder().encode(pin)
        #expect(try JSONDecoder().decode(BrowserTab.self, from: data) == pin)
    }

    @Test func customNamesSurviveNavigationPinResetCloseAndSerialization() throws {
        let page = tab()
        let browser = coordinator(tabs: [page], selected: page.id)
        #expect(browser.renameTab(page.id, to: "  My Videos  "))
        browser.setPinned(page.id, pinned: true)
        browser.updateMetadata(page.id, url: URL(string: "https://example.com/video")!, title: "Video")
        #expect(browser.tabStore.tab(id: page.id)?.displayTitle == "My Videos")
        browser.resetPinnedTab(page.id)
        browser.closeTab(page.id)
        let session = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        #expect(session.tabs.first?.displayTitle == "My Videos")
        browser.openTab(page.id)
        browser.setFavorite(page.id, favorite: true)
        #expect(browser.tabStore.tab(id: page.id)?.customTitle == "My Videos")
        #expect(browser.renameTab(page.id, to: ""))
        #expect(browser.tabStore.tab(id: page.id)?.displayTitle == "Example")
        #expect(browser.activeTabID == page.id)
    }

    @Test func reorderPreservesIdentitySelectionAndPersistsOrder() throws {
        let first = tab(), second = tab(), pin = tab(pinned: true)
        let browser = coordinator(tabs: [first, second, pin], selected: first.id)
        #expect(browser.reorderTab(second.id, relativeTo: first.id, after: false))
        #expect(browser.tabStore.todayTabs(in: space).map(\.id) == [second.id, first.id])
        #expect(browser.activeTabID == first.id)
        #expect(!browser.reorderTab(first.id, relativeTo: pin.id, after: false))
        #expect(!browser.reorderTab(first.id, relativeTo: first.id, after: false))
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        #expect(decoded.tabs.map(\.id) == browser.tabStore.tabs.map(\.id))
        browser.setFavorite(first.id, favorite: true)
        browser.setFavorite(second.id, favorite: true)
        #expect(browser.reorderTab(first.id, relativeTo: second.id, after: false))
        #expect(browser.tabStore.favorites.map(\.id) == [first.id, second.id])
        #expect(browser.tabStore.tabs.count == 3)
        let otherSpace = BrowserTab(spaceID: UUID(), profileID: profile, title: "Other space", currentURL: first.currentURL)
        let otherProfile = BrowserTab(spaceID: space, profileID: UUID(), title: "Other profile", currentURL: first.currentURL,
                                      pinnedURL: first.currentURL, isFavorite: true)
        var store = TabStore(tabs: [first, second, otherSpace, otherProfile])
        let movedAcrossSpaces = store.reorder(first.id, relativeTo: otherSpace.id, after: false)
        let movedToMissingTab = store.reorder(first.id, relativeTo: UUID(), after: false)
        #expect(!movedAcrossSpaces)
        #expect(!movedToMissingTab)
        var favorite = first
        favorite.isFavorite = true
        favorite.pinnedURL = first.currentURL
        store = TabStore(tabs: [favorite, otherProfile])
        let movedAcrossProfiles = store.reorder(favorite.id, relativeTo: otherProfile.id, after: false)
        #expect(!movedAcrossProfiles)
    }

    @Test func legacyPinWithoutSavedTitleLoadsAndLearnsOriginalPageName() throws {
        var pin = tab(pinned: true)
        pin.title = "example.com"
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pin)) as? [String: Any])
        payload.removeValue(forKey: "pinnedTitle")
        payload.removeValue(forKey: "isFavorite")
        let old = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(old.pinnedTitle == nil)
        #expect(!old.isFavorite)
        let browser = coordinator(tabs: [old], selected: old.id)
        browser.updateMetadata(old.id, url: old.pinnedURL, title: "Example")
        browser.updateMetadata(old.id, url: URL(string: "https://example.com/video")!, title: "Video")
        browser.closeTab(old.id)
        #expect(browser.tabStore.tab(id: old.id)?.title == "Example")
        #expect(browser.tabStore.tab(id: old.id)?.pinnedTitle == "Example")
    }

    @Test func pinnedNameSurvivesNavigationResetAndClose() {
        let page = tab()
        let browser = coordinator(tabs: [page], selected: page.id)
        browser.setPinned(page.id, pinned: true)
        let video = URL(string: "https://example.com/video")!
        browser.updateMetadata(page.id, url: video, title: "Video")
        #expect(browser.tabStore.tab(id: page.id)?.title == "Video")
        #expect(browser.tabStore.tab(id: page.id)?.pinnedTitle == "Example")
        browser.resetPinnedTab(page.id)
        #expect(browser.tabStore.tab(id: page.id)?.title == "Example")
        browser.updateMetadata(page.id, url: video, title: "Another video")
        browser.closeTab(page.id)
        #expect(browser.tabStore.tab(id: page.id)?.title == "Example")
        #expect(browser.recentlyClosed.last?.tab.title == "Example")
        browser.setPinned(page.id, pinned: false)
        #expect(browser.tabStore.tab(id: page.id)?.pinnedTitle == nil)
    }

    @Test func pinningCapturesURLOnceAndDoesNotChangeSelection() {
        let first = tab()
        let second = tab()
        let browser = coordinator(tabs: [first, second], selected: first.id)
        #expect(browser.setPinned(second.id, pinned: true))
        #expect(browser.activeTabID == first.id)
        #expect(browser.tabStore.tab(id: second.id)?.pinnedURL == second.currentURL)
        let article = URL(string: "https://example.com/article")!
        browser.updateMetadata(second.id, url: article, title: "Article")
        #expect(!browser.setPinned(second.id, pinned: true))
        #expect(browser.tabStore.tab(id: second.id)?.pinnedURL == second.currentURL)
        #expect(browser.setPinned(second.id, pinned: false))
        #expect(browser.tabStore.tab(id: second.id)?.currentURL == article)
        #expect(browser.tabStore.tab(id: second.id)?.pinnedURL == nil)
        #expect(browser.activeTabID == first.id)
        #expect(browser.tabStore.tabs.map(\.id) == [first.id, second.id])
    }

    @Test func closedPinReopensSameIdentityAtPinnedURLAndClearsClosure() {
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/article")!
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.closeActiveTab()
        browser.presentCommandBar(.newTab)
        browser.dismissCommandBar()
        #expect(browser.content == .empty)
        #expect(browser.tabStore.pinnedTabs(in: space).map(\.id) == [pin.id])
        #expect(browser.tabStore.openTabs(in: space).isEmpty)
        #expect(browser.openTab(pin.id))
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.activeTabID == pin.id)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.pinnedURL)
        #expect(browser.tabStore.tab(id: pin.id)?.pinnedURL == pin.pinnedURL)
        #expect(browser.recentlyClosed.isEmpty)
        #expect(browser.reopenLastTab() == nil)
    }

    @Test func resettingPinNavigatesOriginalURLWithSameIdentity() {
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/article")!
        let browser = coordinator(tabs: [pin], selected: nil)
        #expect(browser.resetPinnedTab(pin.id) == pin.pinnedURL)
        #expect(browser.activeTabID == pin.id)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.pinnedURL)
        browser.closeActiveTab()
        #expect(browser.resetPinnedTab(pin.id) == pin.pinnedURL)
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.tabStore.tab(id: pin.id)?.isOpen == true)
        #expect(browser.recentlyClosed.isEmpty)
    }

    @Test func backgroundPinCloseAndHistoryReopenUseOriginalURL() {
        let selected = tab()
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/video")!
        pin.title = "Video"
        let browser = coordinator(tabs: [selected, pin], selected: selected.id)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.currentURL)
        browser.closeTab(pin.id)
        #expect(browser.activeTabID == selected.id)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.pinnedURL)
        #expect(browser.recentlyClosed.last?.tab.currentURL == pin.pinnedURL)
        #expect(!browser.updateMetadata(pin.id, url: pin.currentURL, title: "Late video title"))
        #expect(browser.tabStore.tab(id: pin.id)?.title == "Example")
        #expect(browser.reopenLastTab() == pin.id)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.pinnedURL)
        #expect(browser.tabStore.tabs.count == 2)
    }

    @Test func unpinningClosedPinMovesItToTodayWithoutSelection() {
        let pin = tab(pinned: true)
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.closeActiveTab()
        #expect(browser.setPinned(pin.id, pinned: false))
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        #expect(browser.tabStore.pinnedTabs(in: space).isEmpty)
        #expect(browser.tabStore.todayTabs(in: space).map(\.id) == [pin.id])
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.currentURL)
        #expect(browser.reopenLastTab() == nil)
        #expect(browser.openTab(pin.id))
        #expect(browser.activeTabID == pin.id)
    }

    @Test func pinActionsRejectMissingOtherSpaceAndNonPinReset() {
        let today = tab()
        let other = tab(pinned: true, in: UUID())
        let browser = coordinator(tabs: [today, other], selected: today.id)
        let before = browser.session
        for id in [UUID(), other.id] {
            #expect(!browser.setPinned(id, pinned: true))
            #expect(!browser.setPinned(id, pinned: false))
            #expect(!browser.openTab(id))
            #expect(browser.resetPinnedTab(id) == nil)
        }
        #expect(browser.resetPinnedTab(today.id) == nil)
        #expect(browser.session == before)
    }

    @Test func closeAndKeyboardOrderFollowPinnedThenTodayOrder() {
        let first = tab()
        let second = tab()
        let pin = tab(pinned: true)
        let browser = coordinator(tabs: [first, second, pin], selected: pin.id)
        #expect(browser.tabStore.openTabs(in: space).map(\.id) == [pin.id, first.id, second.id])
        browser.closeActiveTab()
        #expect(browser.activeTabID == first.id)
        #expect(browser.tabStore.openTabs(in: space).map(\.id) == [first.id, second.id])
        #expect(browser.reopenLastTab() == pin.id)
        #expect(browser.tabStore.tabs.count == 3)
        #expect(browser.tabStore.openTabs(in: space).map(\.id) == [pin.id, first.id, second.id])
    }

    @Test func thirtyTwoPinsRemainOrderedAndClosedWithoutActiveContent() throws {
        let tabs = (0..<32).map { _ in tab() }
        let browser = coordinator(tabs: tabs, selected: tabs[0].id)
        for tab in tabs { #expect(browser.setPinned(tab.id, pinned: true)) }
        for tab in tabs { browser.closeTab(tab.id) }
        #expect(browser.content == .empty)
        #expect(browser.tabStore.openTabs(in: space).isEmpty)
        #expect(browser.tabStore.pinnedTabs(in: space).map(\.id) == tabs.map(\.id))
        #expect(browser.recentlyClosed.count == 20)
        let session = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        let restored = BrowserCoordinator(startup: .returningSession, activeSpaceID: space,
            tabStore: TabStore(tabs: session.tabs), selectionBySpace: session.selectionBySpace,
            profileID: session.profileID, recentlyClosed: session.recentlyClosed)
        #expect(restored.content == .empty)
        #expect(restored.commandBar == nil)
        #expect(restored.openTab(tabs[0].id))
        #expect(restored.tabStore.tabs.count == 32)
        #expect(restored.tabStore.pinnedTabs(in: space).map(\.id) == tabs.map(\.id))
    }

    @Test func favoritingMovesIdentityWithoutChangingSelectionAndOrdersBeforePins() {
        let today = tab()
        let pin = tab(pinned: true)
        let favorite = tab()
        let browser = coordinator(tabs: [today, pin, favorite], selected: today.id)
        #expect(browser.setFavorite(favorite.id, favorite: true))
        #expect(!browser.setFavorite(favorite.id, favorite: true))
        #expect(browser.activeTabID == today.id)
        #expect(browser.tabStore.tabs.count == 3)
        #expect(browser.tabStore.favorites.map(\.id) == [favorite.id])
        #expect(browser.tabStore.todayTabs(in: space).map(\.id) == [today.id])
        #expect(browser.tabStore.openTabs(in: space).map(\.id) == [favorite.id, pin.id, today.id])
        #expect(browser.tabStore.tab(id: favorite.id)?.pinnedURL == favorite.currentURL)
        #expect(browser.tabStore.tab(id: favorite.id)?.pinnedTitle == favorite.title)
        #expect(!browser.setPinned(favorite.id, pinned: false))
    }

    @Test func favoritingAPinKeepsOriginalURLAndRemovingFavoriteKeepsItsLiveLocation() {
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/video")!
        pin.title = "Video"
        let browser = coordinator(tabs: [pin], selected: pin.id)
        #expect(browser.setFavorite(pin.id, favorite: true))
        #expect(browser.tabStore.pinnedTabs(in: space).isEmpty)
        #expect(browser.tabStore.tab(id: pin.id)?.pinnedURL == pin.pinnedURL)
        #expect(browser.setFavorite(pin.id, favorite: false))
        #expect(browser.tabStore.todayTabs(in: space).map(\.id) == [pin.id])
        #expect(browser.tabStore.pinnedTabs(in: space).isEmpty)
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.currentURL)
        #expect(browser.tabStore.tab(id: pin.id)?.pinnedURL == nil)
        #expect(browser.tabStore.tab(id: pin.id)?.pinnedTitle == nil)
        #expect(browser.activeTabID == pin.id)
        #expect(browser.tabStore.tabs.count == 1)
    }

    @Test func favoriteIsSharedAcrossSpacesAndClosingClearsOtherSelections() {
        let first = tab()
        let otherSpace = UUID()
        let other = tab(in: otherSpace)
        let browser = coordinator(tabs: [first, other], selected: first.id)
        browser.setFavorite(first.id, favorite: true)
        browser.switchSpace(to: otherSpace)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        #expect(browser.openTab(first.id))
        let article = URL(string: "https://example.com/article")!
        #expect(browser.navigate(to: article, target: .currentTab(first.id)) == first.id)
        #expect(browser.resetPinnedTab(first.id) == first.currentURL)
        browser.closeActiveTab()
        #expect(browser.activeTabID == other.id)
        #expect(browser.session.selectionBySpace[space] == nil)
        #expect(browser.tabStore.favorites.first?.isOpen == false)
        #expect(browser.tabStore.favorites.first?.currentURL == first.currentURL)
        #expect(browser.reopenLastTab() == first.id)
        #expect(browser.activeSpaceID == otherSpace)
        #expect(browser.tabStore.tabs.count == 2)
        browser.switchSpace(to: space)
        #expect(browser.content == .empty)
    }

    @Test func removingGlobalFavoriteMovesRegularTabToCurrentSpaceAndPrunesStaleSelection() {
        let pin = tab(pinned: true)
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.setFavorite(pin.id, favorite: true)
        let otherSpace = browser.createSpace(name: "Other")!
        browser.switchSpace(to: otherSpace)
        browser.openTab(pin.id)
        #expect(browser.setFavorite(pin.id, favorite: false))
        #expect(browser.activeTabID == pin.id)
        #expect(browser.tabStore.tab(id: pin.id)?.spaceID == otherSpace)
        #expect(browser.tabStore.todayTabs(in: otherSpace).map(\.id) == [pin.id])
        #expect(browser.session.selectionBySpace[space] == nil)
        browser.switchSpace(to: space)
        #expect(browser.content == .empty)
        #expect(!browser.openTab(pin.id))
        browser.switchSpace(to: otherSpace)
        #expect(browser.activeTabID == pin.id)
    }

    @Test func closedFavoriteRemovalCreatesUnselectedRegularTabWithoutStaleHistory() {
        let pin = tab(pinned: true)
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.closeActiveTab()
        #expect(browser.setFavorite(pin.id, favorite: true))
        #expect(browser.content == .empty)
        #expect(browser.tabStore.favorites.first?.isOpen == false)
        #expect(browser.reopenLastTab() == nil)
        browser.openTab(pin.id)
        browser.closeActiveTab()
        #expect(browser.setFavorite(pin.id, favorite: false))
        #expect(browser.content == .empty)
        #expect(browser.tabStore.tab(id: pin.id)?.isOpen == true)
        #expect(browser.tabStore.tab(id: pin.id)?.pinnedURL == nil)
        #expect(browser.reopenLastTab() == nil)
        #expect(browser.tabStore.todayTabs(in: space).map(\.id) == [pin.id])
    }

    @Test func favoritesRejectForeignProfileOtherSpaceAndMissingActions() {
        let other = tab(in: UUID())
        let foreign = BrowserTab(spaceID: space, profileID: UUID(), title: "Other profile",
            currentURL: URL(string: "https://example.com")!, pinnedURL: URL(string: "https://example.com")!,
            isFavorite: true)
        let browser = coordinator(tabs: [other, foreign], selected: nil)
        let before = browser.session
        for id in [UUID(), other.id, foreign.id] {
            #expect(!browser.setFavorite(id, favorite: true))
            #expect(!browser.setFavorite(id, favorite: false))
            #expect(!browser.openTab(id))
            #expect(browser.resetPinnedTab(id) == nil)
        }
        #expect(browser.session == before)
    }
}
