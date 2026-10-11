import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct BrowserCoordinatorTests {
    private let space = UUID()
    private let profile = UUID()

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
            selectionBySpace: selected.map { [space: $0] } ?? [:]
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

    @Test func closingPinRetainsIdentityAndBothURLs() {
        var pin = tab(pinned: true)
        pin.currentURL = URL(string: "https://example.com/article")!
        let browser = coordinator(tabs: [pin], selected: pin.id)
        browser.closeActiveTab()
        let stored = browser.tabStore.tab(id: pin.id)
        #expect(stored?.isOpen == false)
        #expect(stored?.pinnedURL == pin.pinnedURL)
        #expect(stored?.currentURL == pin.currentURL)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        browser.selectOpenTab(pin.id)
        #expect(browser.content == .empty)
    }

    @Test func emptySpaceDoesNotManufactureSelectionAndReturningRestoresIt() {
        let existing = tab()
        let browser = coordinator(tabs: [existing], selected: existing.id)
        browser.presentCommandBar(.navigateCurrentTab)
        browser.switchSpace(to: UUID())
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

    @Test func closedPinReopensSameIdentityAtLastURLAndClearsClosure() {
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
        #expect(browser.tabStore.tab(id: pin.id)?.currentURL == pin.currentURL)
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
            recentlyClosed: session.recentlyClosed)
        #expect(restored.content == .empty)
        #expect(restored.commandBar == nil)
        #expect(restored.openTab(tabs[0].id))
        #expect(restored.tabStore.tabs.count == 32)
        #expect(restored.tabStore.pinnedTabs(in: space).map(\.id) == tabs.map(\.id))
    }
}
