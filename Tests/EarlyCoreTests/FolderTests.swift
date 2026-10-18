// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct FolderTests {
    @Test func creatingSubfolderRevealsAncestorsAndKeepsNewChildCollapsed() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let root = try #require(browser.createFolder(name: "Root"))
        let child = try #require(browser.createFolder(name: "Child", parentID: root))
        browser.setFolderExpanded(root, expanded: false)
        browser.setFolderExpanded(child, expanded: false)
        let grandchild = try #require(browser.createFolder(name: "New child", parentID: child))
        #expect(browser.folders.first { $0.id == root }?.isExpanded == true)
        #expect(browser.folders.first { $0.id == child }?.isExpanded == true)
        #expect(browser.folders.first { $0.id == grandchild }?.isExpanded == false)
        #expect(browser.activeTabID == nil)
        #expect(browser.tabStore.tabs.isEmpty)
    }

    @Test func emptyFoldersToggleOpenStateAndStillAcceptTabsAndSubfolders() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let folder = try #require(browser.createFolder(name: "Empty"))
        browser.toggleFolder(folder)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == true)
        browser.toggleFolder(folder)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == false)
        browser.setFolderExpanded(folder, expanded: true)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == true)
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: folder).isEmpty)
        let tab = try #require(browser.navigate(to: URL(string: "https://example.com")!,
                                                target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.placeTab(tab, in: .pinned, folderID: folder))
        #expect(browser.tabStore.tab(id: tab)?.folderID == folder)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == true)
        browser.toggleFolder(folder)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == false)
        browser.toggleFolder(folder)
        #expect(browser.folders.first { $0.id == folder }?.isExpanded == true)
        let parent = try #require(browser.createFolder(name: "Parent"))
        let child = try #require(browser.createFolder(name: "Child", parentID: parent))
        #expect(browser.folders.first { $0.id == parent }?.isExpanded == true)
        #expect(browser.folders.first { $0.id == child }?.isExpanded == false)
        browser.toggleFolder(child)
        #expect(browser.folders.first { $0.id == child }?.isExpanded == true)
    }

    @Test func deletingFolderRemovesEntireSubtreeAndClosedHistory() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let root = try #require(browser.createFolder(name: "Delete me"))
        let child = try #require(browser.createFolder(name: "Child", parentID: root))
        let sibling = try #require(browser.createFolder(name: "Keep me"))
        let first = try #require(browser.navigate(to: URL(string: "https://example.com/one")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.moveTab(first, toFolder: root))
        let closed = try #require(browser.navigate(to: URL(string: "https://example.com/two")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.moveTab(closed, toFolder: child))
        #expect(browser.closeTab(closed) == closed)
        let survivor = try #require(browser.navigate(to: URL(string: "https://example.com/keep")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.moveTab(survivor, toFolder: sibling))
        browser.selectOpenTab(first)
        let removed = try #require(browser.deleteFolder(root))
        #expect(removed == Set([first, closed]))
        #expect(browser.folders.map(\.id) == [sibling])
        #expect(browser.tabStore.tabs.map(\.id) == [survivor])
        #expect(browser.activeTabID == survivor)
        #expect(browser.recentlyClosed.isEmpty)
        #expect(browser.reopenLastTab() == nil)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        try decoded.validate()
        #expect(decoded.folders.map(\.id) == [sibling])
        #expect(decoded.tabs.map(\.id) == [survivor])
    }

    @Test func deletingLastFolderLeavesEmptyContentWithoutOpeningCommandBar() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let folder = try #require(browser.createFolder(name: "Last"))
        let tab = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.moveTab(tab, toFolder: folder))
        #expect(browser.deleteFolder(folder) == Set([tab]))
        #expect(browser.activeTabID == nil)
        #expect(browser.content == .empty)
        #expect(browser.commandBar == nil)
        #expect(browser.tabStore.tabs.isEmpty)
        #expect(browser.session.selectionBySpace.isEmpty)
        try browser.session.validate()
        let snapshot = browser.session
        #expect(browser.deleteFolder(folder) == nil)
        #expect(browser.session == snapshot)
    }

    @Test func deletingEmptyFolderPreservesUnrelatedSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let folder = try #require(browser.createFolder(name: "Empty"))
        let tab = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.deleteFolder(folder) == Set<UUID>())
        #expect(browser.activeTabID == tab)
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.folders.isEmpty)
    }

    @Test func foldersStartCollapsedAndRestoreCollapsed() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let root = try #require(browser.createFolder(name: "Root"))
        let child = try #require(browser.createFolder(name: "Child", parentID: root))
        #expect(browser.folders.first { $0.id == root }?.isExpanded == true)
        #expect(browser.folders.first { $0.id == child }?.isExpanded == false)
        browser.setFolderExpanded(root, expanded: true)
        browser.setFolderExpanded(child, expanded: true)
        let session = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        let restored = BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), profileID: session.profileID)
        #expect(restored.folders.allSatisfy { !$0.isExpanded })
        #expect(restored.folders.first(where: { $0.id == child })?.parentID == root)
    }

    @Test func folderPlacementOrdersMixedSiblingsAndRejectsInvalidMovesAtomically() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let a = try #require(browser.createFolder(name: "A"))
        let b = try #require(browser.createFolder(name: "B"))
        let child = try #require(browser.createFolder(name: "Child", parentID: a))
        let tab = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.placeTab(tab, in: .pinned, before: b))
        #expect(browser.placeFolder(b, in: nil, before: tab))
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: nil).map(\.id) == [a, b, tab])
        #expect(browser.placeFolder(b, in: a, before: child))
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: a).map(\.id) == [b, child])
        let before = browser.session
        #expect(!browser.placeFolder(a, in: child, before: nil))
        #expect(!browser.placeFolder(b, in: b, before: nil))
        #expect(!browser.placeFolder(b, in: nil, before: UUID()))
        #expect(browser.session == before)
        #expect(browser.placeFolder(b, in: nil, before: a))
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: nil).map(\.id) == [b, a, tab])
        #expect(browser.activeTabID == tab)
        #expect(browser.tabStore.tabs.count == 1)
    }

    @Test func mixedPlacementPersistsAndInvalidDropIsAtomic() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let a = try #require(browser.createFolder(name: "A"))
        let b = try #require(browser.createFolder(name: "B"))
        let id = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        #expect(browser.placeTab(id, in: .pinned, before: b))
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: nil).map(\.id) == [a, id, b])
        #expect(browser.placeTab(id, in: .pinned, before: a))
        #expect(browser.tabStore.pinnedItems(in: browser.activeSpaceID, parentID: nil).map(\.id) == [id, a, b])
        #expect(browser.placeTab(id, in: .pinned, folderID: b))
        #expect(browser.tabStore.tab(id: id)?.folderID == b)
        let before = browser.session
        #expect(!browser.placeTab(id, in: .favorites, before: UUID()))
        #expect(browser.session == before)
        #expect(!browser.placeTab(id, in: .pinned, folderID: UUID()))
        #expect(browser.session == before)
        #expect(browser.placeTab(id, in: .pinned, before: b))
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        try decoded.validate()
        let store = TabStore(tabs: decoded.tabs, folders: decoded.folders)
        #expect(store.pinnedItems(in: browser.activeSpaceID, parentID: nil).map(\.id) == [a, id, b])
        #expect(browser.activeTabID == id)
    }

    @Test func folderMovesPreserveIdentityAndRoundTrip() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let id = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        let root = try #require(browser.createFolder(name: " Work "))
        let child = try #require(browser.createFolder(name: "Videos", parentID: root))
        #expect(browser.moveTab(id, toFolder: child))
        #expect(browser.activeTabID == id)
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.tabStore.tab(id: id)?.pinnedURL != nil)
        #expect(!browser.moveFolder(root, to: child))
        #expect(!browser.moveFolder(root, to: root))
        #expect(!browser.moveFolder(child, to: UUID()))
        #expect(browser.renameFolder(child, to: "Clips"))
        browser.toggleFolder(root)
        var session = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        try session.validate()
        #expect(session.folders.first?.isExpanded == false)
        #expect(session.folders.last?.name == "Clips")
        #expect(session.tabs.first?.folderID == child)
        let restored = BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), profileID: session.profileID)
        #expect(restored.moveFolder(child, to: nil))
        #expect(restored.moveTab(id, toFolder: nil))
        #expect(restored.tabStore.tab(id: id)?.pinnedURL != nil)
        #expect(restored.moveTab(id, toFolder: child))
        #expect(restored.setFavorite(id, favorite: true))
        #expect(restored.tabStore.tab(id: id)?.folderID == nil)
        #expect(!restored.moveTab(id, toFolder: child))
        session.folders[0].parentID = child
        #expect(throws: SessionError.self) { try session.validate() }
    }

    @Test func legacySessionsAndFolderBoundaries() throws {
        let old = BrowserSession()
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        payload.removeValue(forKey: "folders")
        let legacy = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.folders.isEmpty)
        let space = UUID(), other = UUID()
        var store = TabStore()
        let rootResult = store.createFolder(name: "A", parentID: nil, spaceID: space)
        let foreignResult = store.createFolder(name: "B", parentID: nil, spaceID: other)
        let root = try #require(rootResult)
        let foreign = try #require(foreignResult)
        #expect(!store.canMoveFolder(root, to: foreign))
        let invalid = store.createFolder(name: " ", parentID: nil, spaceID: space)
        #expect(invalid == nil)
        var parent = root
        for _ in 1...BrowserFolder.maximumNestingDepth {
            let result = store.createFolder(name: "Nested", parentID: parent, spaceID: space)
            parent = try #require(result)
        }
        let before = store
        #expect(!store.canCreateFolder(in: parent, spaceID: space))
        let tooDeep = store.createFolder(name: "Too deep", parentID: parent, spaceID: space)
        #expect(tooDeep == nil)
        #expect(store == before)
        // Depth is limited, not the number of sibling folders.
        for index in 0..<5 {
            let sibling = store.createFolder(name: "Sibling \(index)", parentID: root, spaceID: space)
            #expect(sibling != nil)
        }
    }

    @Test func subtreeMovesRespectTwoNestedLevelsAndRejectionsAreAtomic() throws {
        let space = UUID()
        var store = TabStore()
        let rootResult = store.createFolder(name: "Root", parentID: nil, spaceID: space)
        let root = try #require(rootResult)
        let childResult = store.createFolder(name: "Child", parentID: root, spaceID: space)
        let child = try #require(childResult)
        let leafResult = store.createFolder(name: "Leaf", parentID: child, spaceID: space)
        let leaf = try #require(leafResult)
        let otherResult = store.createFolder(name: "Other", parentID: nil, spaceID: space)
        let other = try #require(otherResult)
        let before = store
        #expect(!store.canMoveFolder(other, to: leaf))
        let invalidPlacement = store.placeFolder(other, in: leaf, before: nil)
        #expect(!invalidPlacement)
        #expect(!store.canMoveFolder(root, to: other)) // Its grandchild would be depth 3.
        let invalidMove = store.moveFolder(root, to: other)
        #expect(!invalidMove)
        #expect(store == before)
        let validPlacement = store.placeFolder(child, in: other, before: nil)
        #expect(validPlacement) // Child + leaf still fit.
        #expect(BrowserFolder.nestingDepth(of: leaf, in: store.folders) == 2)
        let lifted = store.moveFolder(leaf, to: nil)
        #expect(lifted)
        #expect(BrowserFolder.nestingDepth(of: leaf, in: store.folders) == 0)
    }

    @Test func legacyDeeperHierarchyStaysReadableAndCanBeMovedToShallowerParents() throws {
        let space = UUID()
        let root = BrowserFolder(spaceID: space, name: "Root")
        let child = BrowserFolder(spaceID: space, parentID: root.id, name: "Child")
        let grandchild = BrowserFolder(spaceID: space, parentID: child.id, name: "Grandchild")
        let oldDeep = BrowserFolder(spaceID: space, parentID: grandchild.id, name: "Previously allowed")
        var store = TabStore(folders: [root, child, grandchild, oldDeep])
        try BrowserFolder.validate(store.folders)
        let rejected = store.createFolder(name: "Deeper", parentID: oldDeep.id, spaceID: space)
        #expect(rejected == nil)
        #expect(store.folders.last?.parentID == grandchild.id)
        let moved = store.moveFolder(oldDeep.id, to: root.id)
        #expect(moved)
        #expect(BrowserFolder.nestingDepth(of: oldDeep.id, in: store.folders) == 1)
        try BrowserFolder.validate(store.folders)
    }
}
