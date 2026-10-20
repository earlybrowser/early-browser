// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SidebarSavedSectionPreviewTests {
    @Test(arguments: [TabStore.Section.favorites, .pinned])
    func emptySavedSectionsShowTheirOutlineBeforeThePointerEnters(section: TabStore.Section) {
        let idle = SidebarSavedSectionPreview(section: section, isDragging: false, hasItems: false, isTargeted: false)
        #expect(!idle.showsOutline && !idle.isActive)
        let draggingElsewhere = SidebarSavedSectionPreview(section: section, isDragging: true, hasItems: false, isTargeted: false)
        #expect(draggingElsewhere.showsOutline && !draggingElsewhere.isActive)
        let hovering = SidebarSavedSectionPreview(section: section, isDragging: true, hasItems: false, isTargeted: true)
        #expect(hovering.showsOutline && hovering.isActive)
        #expect(draggingElsewhere.height == hovering.height, "Hover must not move the centered label or drop region")
        let ended = SidebarSavedSectionPreview(section: section, isDragging: false, hasItems: false, isTargeted: true)
        #expect(!ended.showsOutline && !ended.isActive)
    }

    @Test func folderOnlyAndClosedPinSectionsAreNotEmptyTargets() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let folderOnly = TabStore(folders: [BrowserFolder(spaceID: space, name: "Empty folder")])
        let closedPin = TabStore(tabs: [BrowserTab(spaceID: space, profileID: profile,
            title: "Closed pin", currentURL: url, pinnedURL: url, isOpen: false)])
        for store in [folderOnly, closedPin] {
            let hasItems = !store.pinnedItems(in: space, parentID: nil).isEmpty
            let preview = SidebarSavedSectionPreview(section: .pinned, isDragging: true, hasItems: hasItems, isTargeted: false)
            #expect(hasItems && !preview.showsOutline && !preview.isActive)
        }
    }

    @Test func todayTabsAndFavoritesDoNotPreventAnEmptyPinsTarget() {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let store = TabStore(tabs: [
            BrowserTab(spaceID: space, profileID: profile, title: "Today", currentURL: url),
            BrowserTab(spaceID: space, profileID: profile, title: "Favorite", currentURL: url, pinnedURL: url, isFavorite: true)
        ])
        let preview = SidebarSavedSectionPreview(section: .pinned, isDragging: true,
            hasItems: !store.pinnedItems(in: space, parentID: nil).isEmpty, isTargeted: false)
        #expect(preview.showsOutline && !preview.isActive)
        #expect(preview.height == 34, "The label and its own outline share one frame, without the Pins end marker")
    }

    @Test func populatedFavoritesAndTodayNeverGetEmptySavedSectionOutlines() {
        let favorites = SidebarSavedSectionPreview(section: .favorites, isDragging: true, hasItems: true, isTargeted: true)
        let today = SidebarSavedSectionPreview(section: .regular, isDragging: true, hasItems: false, isTargeted: true)
        #expect(!favorites.showsOutline && !favorites.isActive)
        #expect(!today.showsOutline && !today.isActive)
        #expect(favorites.height == SidebarReorderLayout.favoriteHeight)
    }
}
