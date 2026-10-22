// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

/// Close Other Tabs, Close Tabs Below and Clear Today Tabs touch only Today
/// tabs in the active Space, and every closed page stays reopenable.
@Suite @MainActor
struct TabCleanupTests {
    private let space = UUID(), other = UUID(), profile = UUID()

    private func tab(_ name: String, pinned: Bool = false, favorite: Bool = false, in spaceID: UUID? = nil) -> BrowserTab {
        let url = URL(string: "https://example.com/\(name)")!
        return BrowserTab(spaceID: spaceID ?? space, profileID: profile, title: name, currentURL: url,
                          pinnedURL: pinned || favorite ? url : nil, isFavorite: favorite)
    }

    private func coordinator(_ tabs: [BrowserTab], selected: UUID) -> BrowserCoordinator {
        BrowserCoordinator(startup: .returningSession, activeSpaceID: space, tabStore: TabStore(tabs: tabs),
            selectionBySpace: [space: selected], profileID: profile,
            spaces: [BrowserSpace(id: space, profileID: profile, name: "Work"),
                     BrowserSpace(id: other, profileID: profile, name: "Home")])
    }

    @Test func closeOtherTabsKeepsSavedPagesAndReopensFromTheTop() throws {
        let pin = tab("pin", pinned: true), favorite = tab("favorite", favorite: true)
        let today = ["a", "b", "c", "d"].map { tab($0) }
        let elsewhere = tab("elsewhere", in: other)
        let coordinator = coordinator([pin, favorite] + today + [elsewhere], selected: today[3].id)
        #expect(coordinator.todayTabIDs(otherThan: today[1].id) == [today[0].id, today[2].id, today[3].id])
        #expect(coordinator.todayTabIDs(otherThan: pin.id).isEmpty, "Saved pages have no Today siblings to close")

        let closed = coordinator.closeTodayTabs(coordinator.todayTabIDs(otherThan: today[1].id), keeping: today[1].id)
        #expect(closed == [today[3].id, today[2].id, today[0].id], "Bottom first")
        #expect(coordinator.activeTabID == today[1].id)
        #expect(coordinator.tabStore.todayTabs(in: space).map(\.id) == [today[1].id])
        #expect(coordinator.tabStore.tab(id: pin.id)?.isOpen == true && coordinator.tabStore.tab(id: favorite.id)?.isOpen == true)
        #expect(coordinator.tabStore.todayTabs(in: other).map(\.id) == [elsewhere.id], "Other Spaces are untouched")

        // Reopen Closed Tab restores them from the top, in place.
        #expect(coordinator.reopenLastTab() == today[0].id)
        #expect(coordinator.reopenLastTab() == today[2].id)
        #expect(coordinator.tabStore.todayTabs(in: space).map(\.id) == [today[0].id, today[1].id, today[2].id])
    }

    @Test func anyRecentlyClosedTabReopensInPlaceWithoutTheNewerOnes() throws {
        let today = ["a", "b", "c"].map { tab($0) }
        let coordinator = coordinator(today, selected: today[0].id)
        #expect(coordinator.closeTodayTabs([today[1].id]) == [today[1].id])
        #expect(coordinator.closeTodayTabs([today[2].id]) == [today[2].id])
        #expect(coordinator.reopenClosedTab(today[1].id) == today[1].id, "History › Recently Closed can pick an older tab")
        #expect(coordinator.activeTabID == today[1].id)
        #expect(coordinator.tabStore.todayTabs(in: space).map(\.id) == [today[0].id, today[1].id], "Back in its place")
        #expect(coordinator.recentlyClosed.map(\.tab.id) == [today[2].id], "The newer closing stays listed")
        #expect(coordinator.reopenClosedTab(today[1].id) == nil && coordinator.reopenClosedTab(UUID()) == nil)
        #expect(coordinator.reopenLastTab() == today[2].id && coordinator.recentlyClosed.isEmpty)
    }

    @Test func closeTabsBelowAndClearTodayLeavePinsSelected() throws {
        let pin = tab("pin", pinned: true)
        let today = ["a", "b", "c"].map { tab($0) }
        let coordinator = coordinator([pin] + today, selected: today[0].id)
        #expect(coordinator.todayTabIDs(below: today[0].id) == [today[1].id, today[2].id])
        #expect(coordinator.todayTabIDs(below: today[2].id).isEmpty && coordinator.todayTabIDs(below: pin.id).isEmpty)
        #expect(coordinator.closeTodayTabs(coordinator.todayTabIDs(below: today[0].id), keeping: today[0].id).count == 2)
        #expect(coordinator.todayTabIDs == [today[0].id] && coordinator.activeTabID == today[0].id)

        #expect(coordinator.closeTodayTabs(coordinator.todayTabIDs) == [today[0].id])
        #expect(coordinator.todayTabIDs.isEmpty && coordinator.tabStore.tab(id: pin.id)?.isOpen == true)
        #expect(coordinator.closeTodayTabs([pin.id]).isEmpty, "A pin passed in by mistake is never closed")
        #expect(coordinator.recentlyClosed.map(\.tab.id).suffix(3) == [today[2].id, today[1].id, today[0].id])
    }
}

/// Reopen Closed Window combines the closed window's Today tabs with the
/// profile's saved items as they are now.
@Suite @MainActor
struct ReopenedWindowTests {
    @Test func todayTabsComeBackWithTheCurrentSavedItemsAndSpaces() throws {
        let profile = UUID()
        let work = BrowserSpace(profileID: profile, name: "Work"), gone = BrowserSpace(profileID: profile, name: "Gone")
        let page = BrowserTab(spaceID: work.id, profileID: profile, title: "Page", currentURL: URL(string: "https://example.com/page")!)
        let lost = BrowserTab(spaceID: gone.id, profileID: profile, title: "Lost", currentURL: URL(string: "https://example.com/lost")!)
        let oldPin = BrowserTab(spaceID: work.id, profileID: profile, title: "Old pin", currentURL: URL(string: "https://example.com/old")!,
                                pinnedURL: URL(string: "https://example.com/old")!)
        let closed = BrowserSession(profileID: profile, activeSpaceID: gone.id, tabs: [oldPin, page, lost],
                                    selectionBySpace: [work.id: page.id, gone.id: lost.id], spaces: [work, gone])
        #expect(closed.hasTodayTabs && !closed.savedItemsOnly.hasTodayTabs)

        let newPin = BrowserTab(spaceID: work.id, profileID: profile, title: "New pin", currentURL: URL(string: "https://example.com/new")!,
                                pinnedURL: URL(string: "https://example.com/new")!)
        let current = BrowserSession(profileID: profile, activeSpaceID: work.id, tabs: [newPin], spaces: [work])
        let reopened = closed.reopeningWindow(savedItemsFrom: current)
        try reopened.validate()
        #expect(reopened.tabs.map(\.title) == ["New pin", "Page"], "Current pins, and the Today tabs whose Space still exists")
        #expect(reopened.tabs.first { $0.title == "New pin" }?.isOpen == false, "Saved pages start closed")
        #expect(reopened.activeSpaceID == work.id && reopened.selectionBySpace == [work.id: page.id])
        #expect(reopened.spaces == [work])
    }
}
