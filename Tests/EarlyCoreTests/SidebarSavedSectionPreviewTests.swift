// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SidebarSavedSectionPreviewTests {
    @Test(arguments: [TabStore.Section.favorites, .pinned])
    func emptySavedSectionsShowTheirOutlineBeforeThePointerEnters(section: TabStore.Section) {
        let source = UUID()
        let idle = SidebarSavedSectionPreview(section: section, itemIDs: [], draggingItemID: nil, isTargeted: false)
        #expect(!idle.showsOutline && !idle.isActive)
        let draggingElsewhere = SidebarSavedSectionPreview(section: section, itemIDs: [], draggingItemID: source, isTargeted: false)
        #expect(draggingElsewhere.showsOutline && !draggingElsewhere.isActive)
        #expect(draggingElsewhere.sourceSlotID == nil, "An incoming item uses the empty section target, not a retained source row")
        let hovering = SidebarSavedSectionPreview(section: section, itemIDs: [], draggingItemID: source, isTargeted: true)
        #expect(hovering.showsOutline && hovering.isActive)
        #expect(draggingElsewhere.height == hovering.height, "Hover must not move the centered label or drop region")
        let ended = SidebarSavedSectionPreview(section: section, itemIDs: [], draggingItemID: nil, isTargeted: true)
        #expect(!ended.showsOutline && !ended.isActive)
    }

    @Test func folderOnlyAndClosedPinSectionsAreNotEmptyTargets() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let folderOnly = TabStore(folders: [BrowserFolder(spaceID: space, name: "Empty folder")])
        let closedPin = TabStore(tabs: [BrowserTab(spaceID: space, profileID: profile,
            title: "Closed pin", currentURL: url, pinnedURL: url, isOpen: false)])
        for store in [folderOnly, closedPin] {
            let ids = store.pinnedItems(in: space, parentID: nil).map(\.id)
            let preview = SidebarSavedSectionPreview(section: .pinned, itemIDs: ids, draggingItemID: UUID(), isTargeted: false)
            #expect(!ids.isEmpty && !preview.showsEmptyTarget && !preview.showsOutline && !preview.isActive)
        }
    }

    @Test func todayTabsAndFavoritesDoNotPreventAnEmptyPinsTarget() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let store = TabStore(tabs: [
            BrowserTab(spaceID: space, profileID: profile, title: "Today", currentURL: url),
            BrowserTab(spaceID: space, profileID: profile, title: "Favorite", currentURL: url, pinnedURL: url, isFavorite: true)
        ])
        let preview = SidebarSavedSectionPreview(section: .pinned,
            itemIDs: store.pinnedItems(in: space, parentID: nil).map(\.id), draggingItemID: store.tabs[0].id, isTargeted: false)
        #expect(preview.showsOutline && !preview.isActive)
        #expect(preview.height == 34, "The label and its own outline share one frame, without the Pins end marker")
    }

    @Test func populatedFavoritesAndTodayNeverGetEmptySavedSectionOutlines() {
        let source = UUID()
        let favorites = SidebarSavedSectionPreview(section: .favorites, itemIDs: [UUID()], draggingItemID: source, isTargeted: true)
        let today = SidebarSavedSectionPreview(section: .regular, itemIDs: [source], draggingItemID: source, isTargeted: true)
        #expect(!favorites.showsOutline && !favorites.isActive)
        #expect(!today.showsEmptyTarget && !today.showsOutline && !today.isActive && today.sourceSlotID == nil)
        #expect(favorites.height == SidebarReorderLayout.favoriteHeight)
    }

    @Test(arguments: [TabStore.Section.favorites, .pinned])
    func liftingLastSavedTabReusesItsSlotUntilDropOrCancellation(section: TabStore.Section) {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Last saved tab", currentURL: url,
            pinnedURL: url, isFavorite: section == .favorites)
        let store = TabStore(tabs: [tab]), saved = store
        let ids = section == .favorites ? store.favorites.map(\.id) : store.pinnedItems(in: space, parentID: nil).map(\.id)
        let idle = SidebarSavedSectionPreview(section: section, itemIDs: ids, draggingItemID: nil, isTargeted: false)
        #expect(!idle.showsEmptyTarget && idle.sourceSlotID == nil)
        for targeted in [true, false, true] {
            let lifted = SidebarSavedSectionPreview(section: section, itemIDs: ids, draggingItemID: tab.id, isTargeted: targeted)
            #expect(lifted.showsEmptyTarget && lifted.showsOutline)
            #expect(lifted.isActive == targeted)
            #expect(lifted.sourceSlotID == tab.id, "Keep the original view/gesture and reuse its row instead of adding another slot")
            #expect(lifted.height == idle.height)
        }
        let cancelled = SidebarSavedSectionPreview(section: section, itemIDs: ids, draggingItemID: nil, isTargeted: false)
        #expect(cancelled == idle)
        #expect(store == saved, "Pickup, preview, and cancellation must not change saved membership or identity")
    }

    @Test(arguments: [TabStore.Section.favorites, .pinned])
    func liftingOneOfSeveralSavedTabsDoesNotEmptyTheSection(section: TabStore.Section) {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let store = TabStore(tabs: (0..<2).map {
            BrowserTab(spaceID: space, profileID: profile, title: "Saved tab \($0)", currentURL: url,
                pinnedURL: url, isFavorite: section == .favorites)
        })
        let ids = section == .favorites ? store.favorites.map(\.id) : store.pinnedItems(in: space, parentID: nil).map(\.id)
        for source in ids {
            let preview = SidebarSavedSectionPreview(section: section, itemIDs: ids, draggingItemID: source, isTargeted: true)
            #expect(!preview.showsEmptyTarget && !preview.showsOutline && preview.sourceSlotID == nil)
        }
    }

    @Test func liftingOnlyRootFolderEmptiesPinsButLiftingItsDescendantDoesNot() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let root = BrowserFolder(spaceID: space, name: "Only root", isExpanded: true)
        let child = BrowserFolder(spaceID: space, parentID: root.id, name: "Child", isExpanded: true)
        var tab = BrowserTab(spaceID: space, profileID: profile, title: "Nested pin", currentURL: url, pinnedURL: url)
        tab.folderID = child.id
        let store = TabStore(tabs: [tab], folders: [root, child]), saved = store
        let ids = store.pinnedItems(in: space, parentID: nil).map(\.id)
        let lifted = SidebarSavedSectionPreview(section: .pinned, itemIDs: ids, draggingItemID: root.id, isTargeted: false)
        #expect(lifted.showsOutline && lifted.sourceSlotID == root.id)
        for descendant in [child.id, tab.id] {
            let preview = SidebarSavedSectionPreview(section: .pinned, itemIDs: ids, draggingItemID: descendant, isTargeted: true)
            #expect(!preview.showsEmptyTarget && !preview.showsOutline && preview.sourceSlotID == nil)
        }
        #expect(store == saved, "Lifting the folder must not detach its descendants")
    }

    @Test func emptyFoldersAndClosedPinsStillCountWhileAnotherPinIsLifted() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let source = BrowserTab(spaceID: space, profileID: profile, title: "Source", currentURL: url, pinnedURL: url)
        let closed = BrowserTab(spaceID: space, profileID: profile, title: "Closed", currentURL: url, pinnedURL: url, isOpen: false)
        for store in [TabStore(tabs: [source], folders: [BrowserFolder(spaceID: space, name: "Empty folder")]),
                      TabStore(tabs: [source, closed])] {
            let preview = SidebarSavedSectionPreview(section: .pinned,
                itemIDs: store.pinnedItems(in: space, parentID: nil).map(\.id), draggingItemID: source.id, isTargeted: false)
            #expect(!preview.showsEmptyTarget && !preview.showsOutline && preview.sourceSlotID == nil)
        }
    }

    @Test func successfulCrossSectionDropStopsRetainingTheOldSourceSlot() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Saved tab", currentURL: url, pinnedURL: url)
        var store = TabStore(tabs: [tab])
        let before = SidebarSavedSectionPreview(section: .pinned,
            itemIDs: store.pinnedItems(in: space, parentID: nil).map(\.id), draggingItemID: tab.id, isTargeted: false)
        #expect(before.showsOutline && before.sourceSlotID == tab.id)
        let placed = store.place(tab.id, in: .favorites, spaceID: space)
        #expect(placed)
        let after = SidebarSavedSectionPreview(section: .pinned,
            itemIDs: store.pinnedItems(in: space, parentID: nil).map(\.id), draggingItemID: tab.id, isTargeted: false)
        #expect(after.showsOutline && after.sourceSlotID == nil)
        let ended = SidebarSavedSectionPreview(section: .favorites,
            itemIDs: store.favorites.map(\.id), draggingItemID: nil, isTargeted: false)
        #expect(!ended.showsEmptyTarget && !ended.showsOutline && ended.sourceSlotID == nil)
        #expect(store.favorites.map(\.id) == [tab.id])
    }
}
