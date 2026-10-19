// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct SpaceStateTests {
    private let home = URL(string: "https://example.com/")!

    private func restore(_ session: BrowserSession) -> BrowserCoordinator {
        BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders),
            selectionBySpace: session.selectionBySpace, profileID: session.profileID,
            recentlyClosed: session.recentlyClosed, spaces: session.spaces)
    }

    private func open(_ browser: BrowserCoordinator, path: String = "") throws -> UUID {
        try #require(browser.navigate(to: home.appendingPathComponent(path),
            target: .newTab(spaceID: browser.activeSpaceID)))
    }

    @Test func reorderingOnlyChangesCatalogOrderAndRoundTripsWithoutChangingSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Keep folder"))
        let pin = try open(browser, path: "pin")
        browser.moveTab(pin, toFolder: folder)
        browser.closeTab(pin)
        let selected = try open(browser, path: "live")
        let work = try #require(browser.createSpace(name: "Work"))
        let research = try #require(browser.createSpace(name: "Research"))
        browser.switchSpace(to: work)
        _ = try open(browser, path: "work")
        browser.switchSpace(to: personal)
        browser.presentCommandBar(.newTab)
        browser.updateQuery("keep the query")
        let commandBar = browser.commandBar
        let content = browser.content
        var expected = browser.session
        #expect(browser.reorderSpace(personal, before: nil))
        expected.spaces = [expected.spaces[1], expected.spaces[2], expected.spaces[0]]
        #expect(browser.session == expected)
        #expect(browser.activeTabID == selected && browser.activeSpaceID == personal)
        #expect(browser.commandBar == commandBar && browser.content == content)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        let restored = restore(decoded)
        #expect(restored.spaces.map(\.id) == [work, research, personal])
        #expect(restored.activeSpaceID == personal && restored.activeTabID == selected)
        #expect(browser.reorderSpace(personal, before: work))
        #expect(browser.spaces.map(\.id) == [personal, work, research])
        #expect(browser.reorderSpace(research, before: work))
        #expect(browser.spaces.map(\.id) == [personal, research, work])
        try browser.session.validate()
    }

    @Test func invalidAndNoOpSpaceReorderingIsAtomic() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        #expect(!browser.reorderSpace(personal, before: nil))
        let work = try #require(browser.createSpace(name: "Work"))
        let before = browser.session
        #expect(!browser.reorderSpace(UUID(), before: work))
        #expect(!browser.reorderSpace(personal, before: UUID()))
        #expect(!browser.reorderSpace(personal, before: personal))
        #expect(!browser.reorderSpace(personal, before: work))
        #expect(!browser.reorderSpace(work, before: nil))
        #expect(browser.session == before)
    }

    @Test func createEditAndRejectInvalidActionsWithoutChangingSelectionOrIntent() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        #expect(browser.spaces.count == 1)
        #expect(browser.activeSpace?.name == "Personal")
        let original = browser.activeSpaceID
        let tab = try open(browser)
        browser.presentCommandBar(.newTab)
        browser.updateQuery("keep this query")
        let bar = browser.commandBar
        let work = try #require(browser.createSpace(name: "  Work  ", color: .purple))
        #expect(browser.spaces.map(\.name) == ["Personal", "Work"])
        #expect(browser.spaces.last?.color == .purple)
        #expect(browser.spaces.last?.profileID == browser.profileID)
        #expect(browser.activeSpaceID == original && browser.activeTabID == tab)
        #expect(browser.commandBar == bar)
        #expect(browser.editSpace(work, name: "Research", color: .green))
        let before = browser.session
        for name in ["", " \n ", "two\nlines", "bad\u{0000}name", String(repeating: "a", count: 65)] {
            #expect(browser.createSpace(name: name) == nil)
            #expect(!browser.editSpace(work, name: name, color: .red))
            #expect(browser.duplicateSpace(work, name: name) == nil)
        }
        #expect(!browser.editSpace(UUID(), name: "Missing", color: .blue))
        #expect(browser.duplicateSpace(UUID(), name: "Missing") == nil)
        #expect(browser.deleteSpace(UUID()) == nil)
        #expect(!browser.switchSpace(to: UUID()))
        #expect(browser.session == before)
        #expect(browser.commandBar == bar)
        try browser.session.validate()
    }

    @Test func emptySpacesPreserveIndependentSelectionAndDoNotCreatePages() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        let first = try open(browser)
        let work = try #require(browser.createSpace(name: "Work"))
        browser.presentCommandBar(.navigateCurrentTab)
        #expect(browser.switchSpace(to: work))
        #expect(browser.content == .empty && browser.commandBar == nil)
        #expect(browser.tabStore.tabs.count == 1)
        let second = try open(browser, path: "work")
        browser.switchSpace(to: personal)
        #expect(browser.activeTabID == first)
        browser.switchSpace(to: work)
        #expect(browser.activeTabID == second)
        browser.closeActiveTab()
        #expect(browser.content == .empty && browser.commandBar == nil)
        browser.switchSpace(to: personal)
        #expect(browser.activeTabID == first)
        browser.switchSpace(to: work)
        #expect(browser.activeTabID == nil)
        let restored = restore(browser.session)
        #expect(restored.spaces == browser.spaces)
        #expect(restored.activeSpaceID == work && restored.activeTabID == nil)
        restored.switchSpace(to: personal)
        #expect(restored.activeTabID == first)
        try restored.session.validate()
    }

    @Test func duplicationCopiesOnlySavedHierarchyWithFreshClosedIdentitiesAndOrder() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Parent"))
        let child = try #require(browser.createFolder(name: "Child", parentID: folder))
        let nestedPin = try open(browser, path: "saved")
        browser.moveTab(nestedPin, toFolder: child)
        browser.renameTab(nestedPin, to: "Custom pin")
        browser.navigate(to: home.appendingPathComponent("live-detour"), target: .currentTab(nestedPin))
        let rootPin = try open(browser, path: "root")
        browser.setPinned(rootPin, pinned: true)
        browser.placeTab(rootPin, in: .pinned, before: folder)
        let favorite = try open(browser, path: "favorite")
        browser.setFavorite(favorite, favorite: true)
        let today = try open(browser, path: "today")
        let before = browser.session
        let copy = try #require(browser.duplicateSpace(source, name: "Copy"))
        #expect(browser.activeTabID == today && browser.activeSpaceID == source)
        #expect(browser.tabStore.favorites.map(\.id) == [favorite])
        #expect(browser.tabStore.tabs.filter { $0.spaceID == source } == before.tabs)
        let copies = browser.tabStore.pinnedTabs(in: copy)
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { !$0.isOpen && $0.currentURL == $0.pinnedURL })
        #expect(Set(copies.map(\.id)).isDisjoint(with: Set(before.tabs.map(\.id))))
        let folders = browser.tabStore.folders.filter { $0.spaceID == copy }
        #expect(folders.count == 2 && folders.allSatisfy { !$0.isExpanded })
        let newParent = try #require(folders.first { $0.name == "Parent" })
        let newChild = try #require(folders.first { $0.name == "Child" })
        #expect(newChild.parentID == newParent.id && newParent.id != folder && newChild.id != child)
        let nested = try #require(copies.first { $0.customTitle == "Custom pin" })
        #expect(nested.folderID == newChild.id && nested.currentURL == home.appendingPathComponent("saved"))
        let rootOrder = browser.tabStore.pinnedItems(in: copy, parentID: nil)
        #expect(rootOrder.count == 2)
        #expect(rootOrder.first?.id == copies.first { $0.folderID == nil }?.id)
        #expect(rootOrder.last?.id == newParent.id)
        browser.switchSpace(to: copy)
        #expect(browser.content == .empty && browser.commandBar == nil)
        #expect(browser.tabStore.todayTabs(in: copy).isEmpty)
        try browser.session.validate()
    }

    @Test func movingTabsPreservesIdentityPinAndOpenStateAndClearsFolderAndOldSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let destination = try #require(browser.createSpace(name: "Destination"))
        let folder = try #require(browser.createFolder(name: "Source folder"))
        let pin = try open(browser, path: "pin")
        browser.moveTab(pin, toFolder: folder)
        browser.navigate(to: home.appendingPathComponent("detour"), target: .currentTab(pin))
        let neighbor = try open(browser, path: "neighbor")
        browser.selectOpenTab(pin)
        let before = try #require(browser.tabStore.tab(id: pin))
        #expect(browser.moveTab(pin, toSpace: destination))
        let moved = try #require(browser.tabStore.tab(id: pin))
        #expect(moved.id == before.id && moved.profileID == before.profileID)
        #expect(moved.isOpen && moved.currentURL == before.currentURL && moved.pinnedURL == before.pinnedURL)
        #expect(moved.folderID == nil && moved.spaceID == destination)
        #expect(browser.activeSpaceID == source && browser.activeTabID == neighbor)
        browser.switchSpace(to: destination)
        #expect(browser.activeTabID == nil)
        browser.openTab(pin)
        browser.closeTab(pin)
        #expect(browser.moveTab(pin, toSpace: source))
        #expect(browser.tabStore.tab(id: pin)?.isOpen == false)
        #expect(browser.recentlyClosed.isEmpty)
        browser.switchSpace(to: source)
        let today = try open(browser, path: "regular")
        #expect(browser.moveTab(today, toSpace: destination))
        #expect(browser.tabStore.tab(id: today)?.pinnedURL == nil)
        #expect(browser.activeTabID == neighbor)
        let favorite = try open(browser, path: "favorite")
        browser.setFavorite(favorite, favorite: true)
        let snapshot = browser.session
        #expect(!browser.moveTab(favorite, toSpace: destination))
        #expect(!browser.moveTab(neighbor, toSpace: source))
        #expect(!browser.moveTab(neighbor, toSpace: UUID()))
        #expect(!browser.moveTab(UUID(), toSpace: destination))
        #expect(browser.session == snapshot)
        try snapshot.validate()
    }

    @Test(arguments: [false, true])
    func followingTabMoveSelectsTheMovedTabAndKeepsSourceFallback(pinned: Bool) throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let moving = try open(browser, path: "move")
        if pinned { browser.setPinned(moving, pinned: true) }
        let neighbor = try open(browser, path: "neighbor")
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.switchSpace(to: destination)
        _ = try open(browser, path: "existing")
        browser.switchSpace(to: source)
        browser.presentCommandBar(.newTab)
        #expect(browser.moveTab(moving, toSpace: destination, follow: true))
        #expect(browser.activeSpaceID == destination && browser.activeTabID == moving)
        #expect(browser.commandBar == nil && browser.tabStore.tabs.count == 3)
        #expect((browser.tabStore.tab(id: moving)?.pinnedURL != nil) == pinned)
        browser.switchSpace(to: source)
        #expect(browser.activeTabID == neighbor)
        try browser.session.validate()
    }

    @Test func followingClosedPinMoveSwitchesSpaceWithoutReopeningIt() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let pin = try open(browser, path: "closed")
        browser.setPinned(pin, pinned: true)
        browser.closeTab(pin)
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.switchSpace(to: destination)
        let existing = try open(browser, path: "existing")
        browser.switchSpace(to: source)
        #expect(browser.moveTab(pin, toSpace: destination, follow: true))
        #expect(browser.activeSpaceID == destination && browser.activeTabID == existing)
        #expect(browser.tabStore.tab(id: pin)?.isOpen == false)
        let snapshot = browser.session
        #expect(!browser.moveTab(pin, toSpace: UUID(), follow: true))
        #expect(browser.session == snapshot)
        try browser.session.validate()
    }

    @Test func followingFolderMoveKeepsItsActiveTabAndDoesNotOpenPagesForEmptyFolders() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Move"))
        let nested = try #require(browser.createFolder(name: "Nested", parentID: folder))
        let empty = try #require(browser.createFolder(name: "Empty"))
        let moving = try open(browser, path: "move")
        browser.moveTab(moving, toFolder: nested)
        let neighbor = try open(browser, path: "neighbor")
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.switchSpace(to: destination)
        _ = try open(browser, path: "existing")
        browser.switchSpace(to: source)
        browser.selectOpenTab(moving)
        #expect(browser.moveFolder(folder, toSpace: destination, follow: true))
        #expect(browser.activeSpaceID == destination && browser.activeTabID == moving)
        browser.switchSpace(to: source)
        #expect(browser.activeTabID == neighbor)
        #expect(browser.moveFolder(empty, toSpace: destination, follow: true))
        #expect(browser.activeSpaceID == destination && browser.activeTabID == moving)
        #expect(browser.tabStore.tabs.count == 3 && browser.commandBar == nil)
        let snapshot = browser.session
        #expect(!browser.moveFolder(folder, toSpace: UUID(), follow: true))
        #expect(browser.session == snapshot)
        try browser.session.validate()
    }

    @Test func movingFolderTransfersItsWholeSubtreeAndKeepsDestinationSelectionAndOrder() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let parent = try #require(browser.createFolder(name: "Parent"))
        let child = try #require(browser.createFolder(name: "Move me", parentID: parent))
        let nested = try #require(browser.createFolder(name: "Nested", parentID: child))
        let live = try open(browser, path: "saved")
        browser.moveTab(live, toFolder: child)
        browser.renameTab(live, to: "Keep my name")
        browser.navigate(to: home.appendingPathComponent("detour"), target: .currentTab(live))
        let closed = try open(browser, path: "closed")
        browser.moveTab(closed, toFolder: nested)
        browser.closeTab(closed)
        let neighbor = try open(browser, path: "neighbor")
        let favorite = try open(browser, path: "favorite")
        browser.setFavorite(favorite, favorite: true)
        let favoriteRecord = browser.tabStore.tab(id: favorite)
        let liveRecord = try #require(browser.tabStore.tab(id: live))
        let childRecord = try #require(browser.folders.first { $0.id == child })
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.switchSpace(to: destination)
        let destinationFolder = try #require(browser.createFolder(name: "Existing folder"))
        let destinationTab = try open(browser, path: "destination")
        browser.setPinned(destinationTab, pinned: true)
        browser.placeTab(destinationTab, in: .pinned, before: destinationFolder)
        let destinationOrder = browser.tabStore.pinnedItems(in: destination, parentID: nil).map(\.id)
        browser.switchSpace(to: source)
        browser.selectOpenTab(live)
        let selectedLiveRecord = try #require(browser.tabStore.tab(id: live))
        browser.presentCommandBar(.newTab)

        #expect(browser.moveFolder(child, toSpace: destination))
        #expect(browser.activeSpaceID == source && browser.activeTabID == neighbor && browser.commandBar == nil)
        #expect(browser.folders.map(\.id) == [parent])
        let movedRoot = try #require(browser.tabStore.folders.first { $0.id == child })
        #expect(movedRoot.spaceID == destination && movedRoot.parentID == nil)
        #expect(movedRoot.name == childRecord.name && movedRoot.isExpanded == childRecord.isExpanded)
        #expect(browser.tabStore.folders.first { $0.id == nested }?.parentID == child)
        #expect(browser.tabStore.folders.first { $0.id == nested }?.spaceID == destination)
        var expected = selectedLiveRecord
        expected.spaceID = destination
        #expect(expected.customTitle == liveRecord.customTitle && expected.currentURL == liveRecord.currentURL)
        #expect(browser.tabStore.tab(id: live) == expected)
        #expect(browser.tabStore.tab(id: closed)?.spaceID == destination)
        #expect(browser.tabStore.tab(id: closed)?.folderID == nested)
        #expect(browser.tabStore.tab(id: closed)?.isOpen == false)
        #expect(browser.recentlyClosed.isEmpty)
        #expect(browser.tabStore.tab(id: favorite) == favoriteRecord)
        #expect(browser.tabStore.pinnedItems(in: destination, parentID: nil).map(\.id) == destinationOrder + [child])
        browser.switchSpace(to: destination)
        #expect(browser.activeTabID == destinationTab)
        #expect(browser.tabStore.openTabs(in: destination).contains { $0.id == live })
        try browser.session.validate()
    }

    @Test func movingEmptyFolderAndRejectingInvalidMovesAreAtomic() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Empty"))
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.presentCommandBar(.newTab)
        browser.updateQuery("keep draft")
        let bar = browser.commandBar
        let before = browser.session
        #expect(!browser.moveFolder(folder, toSpace: source))
        #expect(!browser.moveFolder(folder, toSpace: UUID()))
        #expect(!browser.moveFolder(UUID(), toSpace: destination))
        #expect(browser.session == before && browser.commandBar == bar)
        #expect(browser.moveFolder(folder, toSpace: destination))
        #expect(browser.activeTabID == nil && browser.activeSpaceID == source && browser.commandBar == bar)
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.tabStore.folders.first?.id == folder && browser.tabStore.folders.first?.spaceID == destination)
        try browser.session.validate()
    }

    @Test func movingFolderPrunesSharedSelectionsAndHistoryWithoutChangingOtherWindowLiveURLs() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let source = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Shared"))
        let pin = try open(browser, path: "pin")
        browser.moveTab(pin, toFolder: folder)
        let destination = try #require(browser.createSpace(name: "Destination"))
        let child = restore(browser.session.openingWindow(at: home))
        child.openTab(pin)
        child.navigate(to: home.appendingPathComponent("window-detour"), target: .currentTab(pin))
        let closedWindow = restore(browser.session.openingWindow(at: home))
        closedWindow.openTab(pin)
        closedWindow.closeTab(pin)
        #expect(browser.moveFolder(folder, toSpace: destination))
        #expect(browser.activeSpaceID == source && browser.content == .empty && browser.commandBar == nil)
        child.synchronizeSavedItems(from: browser.session)
        closedWindow.synchronizeSavedItems(from: browser.session)
        #expect(child.activeSpaceID == source && child.activeTabID == nil)
        #expect(child.tabStore.tab(id: pin)?.currentURL == home.appendingPathComponent("window-detour"))
        #expect(child.tabStore.tab(id: pin)?.folderID == folder && child.tabStore.tab(id: pin)?.spaceID == destination)
        #expect(closedWindow.recentlyClosed.isEmpty && closedWindow.reopenLastTab() == nil)
        try child.session.validate()
        try closedWindow.session.validate()
        try browser.session.validate()
    }

    @Test func deletionPreservesGlobalFavoritesAndFallbackSelectionButCannotRemoveLastSpace() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        let keep = try open(browser, path: "keep")
        let work = try #require(browser.createSpace(name: "Work"))
        browser.switchSpace(to: work)
        let folder = try #require(browser.createFolder(name: "Delete subtree"))
        let pin = try open(browser, path: "pin")
        browser.moveTab(pin, toFolder: folder)
        browser.closeTab(pin)
        let today = try open(browser, path: "today")
        let favorite = try open(browser, path: "favorite")
        browser.setFavorite(favorite, favorite: true)
        browser.closeTab(favorite)
        browser.presentCommandBar(.newTab)
        #expect(browser.deleteSpace(work) == Set([pin, today]))
        #expect(browser.spaces.map(\.id) == [personal])
        #expect(browser.activeSpaceID == personal && browser.activeTabID == keep)
        #expect(browser.commandBar == nil && browser.folders.isEmpty)
        #expect(browser.tabStore.favorites.map(\.id) == [favorite])
        #expect(browser.tabStore.tab(id: favorite)?.spaceID == personal)
        #expect(browser.reopenLastTab() == favorite)
        let snapshot = browser.session
        #expect(browser.deleteSpace(personal) == nil)
        #expect(browser.session == snapshot)
        try snapshot.validate()
    }

    @Test func deletingInactiveSpaceKeepsCommandQueryAndRemovesItsHistory() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        let work = try #require(browser.createSpace(name: "Work"))
        browser.switchSpace(to: work)
        let closed = try open(browser)
        browser.closeTab(closed)
        browser.switchSpace(to: personal)
        browser.presentCommandBar(.newTab)
        browser.updateQuery("draft")
        let bar = browser.commandBar
        #expect(browser.deleteSpace(work) == Set<UUID>())
        #expect(browser.commandBar == bar && browser.reopenLastTab() == nil)
        #expect(browser.activeTabID == nil)
        try browser.session.validate()
    }

    @Test func catalogsShareAcrossWindowsWhileTodayAndSelectionStayLocal() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let child = restore(source.session.openingWindow(at: home))
        let local = try #require(child.activeTabID)
        let work = try #require(source.createSpace(name: "Work", color: .red))
        child.synchronizeSavedItems(from: source.session)
        #expect(child.spaces == source.spaces && child.activeTabID == local)
        source.switchSpace(to: work)
        let pin = try open(source)
        source.setPinned(pin, pinned: true)
        child.synchronizeSavedItems(from: source.session)
        child.switchSpace(to: work)
        child.openTab(pin)
        let childToday = try open(child, path: "child")
        #expect(source.tabStore.tab(id: childToday) == nil)
        source.editSpace(work, name: "Renamed", color: .green)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.activeSpace?.name == "Renamed" && child.activeTabID == childToday)
        source.deleteSpace(work)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.spaces == source.spaces)
        #expect(child.activeTabID == local)
        #expect(child.tabStore.tab(id: pin) == nil && child.tabStore.tab(id: childToday) == nil)
        #expect(child.recentlyClosed.isEmpty)
        try child.session.validate()
    }

    @Test func movingSharedPinPrunesOtherWindowSelectionAndKeepsItsLiveDetour() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let original = source.activeSpaceID
        let pin = try open(source)
        source.setPinned(pin, pinned: true)
        let destination = try #require(source.createSpace(name: "Destination"))
        let child = restore(source.session.openingWindow(at: home))
        child.openTab(pin)
        child.navigate(to: home.appendingPathComponent("child-detour"), target: .currentTab(pin))
        source.moveTab(pin, toSpace: destination)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.activeSpaceID == original && child.activeTabID == nil)
        #expect(child.tabStore.tab(id: pin)?.currentURL == home.appendingPathComponent("child-detour"))
        child.switchSpace(to: destination)
        #expect(child.openTab(pin))
        #expect(child.activeTabID == pin)
        try child.session.validate()
    }

    @Test func movedSharedPinCannotBeReopenedIntoItsOldSpaceFromAnotherWindowsHistory() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let pin = try open(source)
        source.setPinned(pin, pinned: true)
        let destination = try #require(source.createSpace(name: "Destination"))
        let child = restore(source.session.openingWindow(at: home))
        child.openTab(pin)
        child.closeTab(pin)
        #expect(child.recentlyClosed.last?.tab.id == pin)
        source.moveTab(pin, toSpace: destination)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.reopenLastTab() == nil)
        #expect(child.tabStore.tab(id: pin)?.spaceID == destination)
        #expect(child.tabStore.tab(id: pin)?.isOpen == false)
        try child.session.validate()
    }

    @Test func movedTodayAppendsWithoutStealingTheDestinationsSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let firstSpace = browser.activeSpaceID
        let first = try open(browser, path: "first")
        let destination = try #require(browser.createSpace(name: "Destination"))
        browser.switchSpace(to: destination)
        let existing = try open(browser, path: "existing")
        browser.switchSpace(to: firstSpace)
        #expect(browser.moveTab(first, toSpace: destination))
        #expect(browser.content == .empty)
        browser.switchSpace(to: destination)
        #expect(browser.activeTabID == existing)
        #expect(browser.tabStore.todayTabs(in: destination).map(\.id) == [existing, first])
        try browser.session.validate()
    }

    @Test func deletingThirdSpaceSelectsPreviousSpaceInEveryAffectedWindow() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let second = try #require(source.createSpace(name: "Second"))
        let third = try #require(source.createSpace(name: "Third"))
        source.switchSpace(to: third)
        let child = restore(source.session.openingWindow(at: home))
        source.deleteSpace(third)
        child.synchronizeSavedItems(from: source.session)
        #expect(source.activeSpaceID == second && child.activeSpaceID == second)
        #expect(child.tabStore.tabs.isEmpty && child.activeTabID == nil)
        try child.session.validate()
    }
}
