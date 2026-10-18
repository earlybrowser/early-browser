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
