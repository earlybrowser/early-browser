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
