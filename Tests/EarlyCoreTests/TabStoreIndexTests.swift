// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite
struct TabStoreIndexTests {
    private func pinned(_ store: TabStore, space: UUID, parent: UUID?) -> [TabStore.PinnedItem] {
        let items = store.folders.filter { $0.spaceID == space && $0.parentID == parent }.map(TabStore.PinnedItem.folder)
            + store.tabs.filter { $0.spaceID == space && $0.folderID == parent && $0.pinnedURL != nil && !$0.isFavorite }.map(TabStore.PinnedItem.tab)
        return items.enumerated().sorted {
            let lhs = $0.element.position ?? Int.max, rhs = $1.element.position ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    private func verify(_ store: TabStore) {
        #expect(store.favorites == store.tabs.filter(\.isFavorite))
        for tab in store.tabs { #expect(store.tab(id: tab.id) == store.tabs.first { $0.id == tab.id }) }
        let spaces = Set(store.tabs.map(\.spaceID) + store.folders.map(\.spaceID))
        for space in spaces {
            #expect(store.folders(in: space) == store.folders.filter { $0.spaceID == space })
            #expect(store.todayTabs(in: space) == store.tabs.filter { $0.spaceID == space && $0.pinnedURL == nil && !$0.isFavorite && $0.isOpen })
            let parents: [UUID?] = [nil] + store.folders.filter { $0.spaceID == space }.map { Optional($0.id) }
            for parent in parents {
                let reference = pinned(store, space: space, parent: parent)
                let actual = store.pinnedItems(in: space, parentID: parent)
                #expect(actual.map(\.id) == reference.map(\.id))
                #expect(store.hasPinnedItems(in: space, parentID: parent) == !reference.isEmpty)
                for (actual, reference) in zip(actual, reference) {
                    switch (actual, reference) {
                    case (.tab(let lhs), .tab(let rhs)): #expect(lhs == rhs)
                    case (.folder(let lhs), .folder(let rhs)): #expect(lhs == rhs)
                    default: Issue.record("A mixed folder/tab order changed its kind")
                    }
                }
            }
            func flatten(_ parent: UUID?) -> [BrowserTab] {
                pinned(store, space: space, parent: parent).flatMap {
                    switch $0 { case .tab(let tab): [tab]; case .folder(let folder): flatten(folder.id) }
                }
            }
            let pins = flatten(nil)
            #expect(store.pinnedTabs(in: space) == pins)
            #expect(store.openTabs(in: space) == store.favorites.filter(\.isOpen) + pins.filter(\.isOpen) + store.todayTabs(in: space))
        }
        for folder in store.folders {
            #expect(store.folder(id: folder.id) == folder)
            #expect(store.folderHierarchy.depth(of: folder.id) == BrowserFolder.nestingDepth(of: folder.id, in: store.folders))
            let ancestors = store.folderHierarchy.ancestors(of: folder.id)
            #expect(ancestors?.first?.id == folder.parentID)
            #expect(ancestors?.count == store.folderHierarchy.depth(of: folder.id))
        }
    }

    @Test func everyMetadataMutationInvalidatesTheDerivedSnapshot() throws {
        let space = UUID(), other = UUID(), profile = UUID()
        var root = BrowserFolder(spaceID: space, name: "Root", isExpanded: true)
        root.sidebarPosition = 1
        let nested = BrowserFolder(spaceID: space, parentID: root.id, name: "Nested", isExpanded: true)
        let url = URL(string: "https://example.invalid/one")!
        var pin = BrowserTab(spaceID: space, profileID: profile, title: "Pin", currentURL: url, pinnedURL: url)
        pin.folderID = nested.id
        let today = BrowserTab(spaceID: space, profileID: profile, title: "Today", currentURL: url)
        var store = TabStore(tabs: [pin, today], folders: [root, nested])
        verify(store)
        let change1 = store.rename(pin.id, to: "Custom"); #expect(change1); verify(store)
        let change2 = store.update(pin.id, url: URL(string: "https://example.invalid/two"), title: "Changed"); #expect(change2); verify(store)
        store.recordActivation(pin.id, at: Date(timeIntervalSince1970: 1_790_000_000)); verify(store)
        store.setFolderExpanded(root.id, expanded: false); verify(store)
        let change3 = store.revealFolderAncestors(of: pin.id); #expect(change3); verify(store)
        let change4 = store.renameFolder(nested.id, to: "Renamed"); #expect(change4); verify(store)
        let change5 = store.setPinned(today.id, pinned: true); #expect(change5); verify(store)
        let change6 = store.moveTab(today.id, toFolder: root.id); #expect(change6); verify(store)
        let change7 = store.placePin(today.id, before: nested.id); #expect(change7); verify(store)
        let change8 = store.setFavorite(today.id, favorite: true, in: space); #expect(change8); verify(store)
        let change9 = store.move(today.id, to: .pinned, in: space); #expect(change9); verify(store)
        let change10 = store.moveFolder(nested.id, to: nil); #expect(change10); verify(store)
        let change11 = store.placeFolder(nested.id, in: nil, before: root.id); #expect(change11); verify(store)
        let created = store.createFolder(name: "Child", parentID: root.id, spaceID: space)
        let child = try #require(created); verify(store)
        #expect(store.folderHierarchy.depth(of: child) == 1)
        let change12 = store.moveFolder(root.id, toSpace: other) != nil; #expect(change12); verify(store)
        store.duplicateSavedItems(in: space, to: other); verify(store)
        let change13 = store.deleteFolder(root.id) != nil; #expect(change13); verify(store)
        _ = store.close(id: today.id); verify(store)
        store.reopen(today.id); verify(store)
        _ = store.resetPinnedLocation(pin.id); verify(store)
        _ = store.deleteSpace(other, rehomeFavoritesTo: space); verify(store)
    }

    @Test func snapshotsStayIndependentAcrossCopiesAndWholeStoreReplacement() async throws {
        let space = UUID(), profile = UUID(), url = URL(string: "https://example.invalid")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Original", currentURL: url, pinnedURL: url)
        let original = TabStore(tabs: [tab])
        _ = original.pinnedTabs(in: space)
        var copy = original
        #expect(copy == original, "Derived cache state does not change model equality")
        let change14 = copy.rename(tab.id, to: "Changed"); #expect(change14)
        verify(copy); verify(original)
        #expect(original.tab(id: tab.id)?.customTitle == nil)
        #expect(copy.pinnedTabs(in: space).first?.customTitle == "Changed")
        let restored = TabStore(tabs: copy.tabs, folders: copy.folders)
        #expect(restored == copy); verify(restored)
        let values = await withTaskGroup(of: String?.self) { group in
            for index in 0..<16 {
                group.addTask {
                    var own = original
                    _ = own.rename(tab.id, to: "Copy \(index)")
                    return own.pinnedTabs(in: space).first?.customTitle
                }
            }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(Set(values.compactMap { $0 }).count == 16)
        #expect(original.pinnedTabs(in: space).first?.customTitle == nil)
    }

    @Test func liveFolderRefreshAndRemovalInvalidateSourceOrderAndMetadata() throws {
        let space = UUID(), profile = UUID(), url = URL(string: "https://example.invalid/pull")!
        var store = TabStore()
        let created = store.createLiveFolder(name: "Pull Requests", source: .githubPullRequests, spaceID: space)
        let folder = try #require(created)
        let items = [LiveFolderItem(id: "one", url: url, title: "One"), LiveFolderItem(id: "two", url: url, title: "Two")]
        let change15 = store.syncLiveFolder(folder, items: items, profileID: profile); #expect(change15); verify(store)
        let first = try #require(store.pinnedTabs(in: space).first?.id)
        store.reopen(first); verify(store)
        let change16 = store.syncLiveFolder(folder, items: [.init(id: "two", url: url, title: "Changed Two")], profileID: profile); #expect(change16); verify(store)
        #expect(store.todayTabs(in: space).map(\.id) == [first])
        let change17 = store.dismissLiveItem(try #require(store.pinnedTabs(in: space).first?.id)); #expect(change17); verify(store)
        #expect(store.pinnedTabs(in: space).isEmpty)
    }

    @Test func hierarchyPreservesLegacyDepthAndDoesNotPoisonShallowerAncestors() {
        let space = UUID()
        var folders = [BrowserFolder(spaceID: space, name: "Root")]
        for index in 1..<40 { folders.append(BrowserFolder(spaceID: space, parentID: folders.last!.id, name: "Level \(index)")) }
        let hierarchy = BrowserFolderHierarchy(Array(folders.reversed()))
        for folder in folders {
            #expect(hierarchy.depth(of: folder.id) == BrowserFolder.nestingDepth(of: folder.id, in: folders))
        }
        #expect(hierarchy.depth(of: folders[8].id) == 8)
        #expect(hierarchy.depth(of: folders[31].id) == 31)
        #expect(hierarchy.depth(of: folders[32].id) == nil)
        var cycle = folders[0]; cycle.parentID = cycle.id
        #expect(BrowserFolderHierarchy([cycle]).ancestors(of: cycle.id) == nil)
    }

    @Test func indexedMoveValidationMatchesFullCandidateValidationIncludingLegacyRepairs() {
        let space = UUID(), other = UUID()
        var folders = [BrowserFolder(spaceID: space, name: "Root")]
        for index in 1..<13 { folders.append(BrowserFolder(spaceID: space, parentID: folders.last!.id, name: "Legacy \(index)")) }
        folders.append(BrowserFolder(spaceID: space, name: "Ordinary"))
        folders.append(BrowserFolder(spaceID: other, name: "Other Space"))
        folders.append(BrowserFolder(spaceID: space, name: "Live", live: LiveFolder(source: .githubPullRequests)))
        var missing = BrowserFolder(spaceID: space, parentID: UUID(), name: "Repair missing parent")
        let stores = [TabStore(folders: folders), TabStore(folders: [missing])]
        func reference(_ store: TabStore, _ id: UUID, _ parentID: UUID?) -> Bool {
            guard let index = store.folders.firstIndex(where: { $0.id == id }),
                  !store.folders.contains(where: { $0.id == parentID && $0.live != nil }) else { return false }
            var candidate = store.folders
            candidate[index].parentID = parentID
            guard (try? BrowserFolder.validate(candidate)) != nil,
                  let depth = BrowserFolder.nestingDepth(of: id, in: candidate) else { return false }
            let children = Dictionary(grouping: store.folders, by: \.parentID)
            var pending = [(id, depth)]
            while let (id, depth) = pending.popLast() {
                guard depth <= BrowserFolder.maximumNestingDepth else { return false }
                pending += (children[id] ?? []).map { ($0.id, depth + 1) }
            }
            return true
        }
        for store in stores {
            let parents: [UUID?] = [nil, UUID()] + store.folders.map { Optional($0.id) }
            for folder in store.folders {
                for parent in parents {
                    #expect(store.canMoveFolder(folder.id, to: parent) == reference(store, folder.id, parent))
                }
            }
        }
        missing.parentID = missing.id
        let cyclic = TabStore(folders: [missing])
        #expect(cyclic.canMoveFolder(missing.id, to: nil) == reference(cyclic, missing.id, nil))
    }

    @Test func bulkStartupCollapseChangesOnlyExpandedPresentation() {
        let space = UUID()
        let folders = (0..<2_000).map { BrowserFolder(spaceID: space, name: "Folder \($0)", isExpanded: $0.isMultiple(of: 2)) }
        var store = TabStore(folders: folders)
        _ = store.pinnedItems(in: space, parentID: nil)
        store.collapseFolders()
        #expect(store.folders == folders.map { folder in var copy = folder; copy.isExpanded = false; return copy })
        let collapsed = store
        store.collapseFolders()
        #expect(store == collapsed)
        verify(store)
    }
}

@Suite
struct TabStoreIndexPerformanceTests {
    @Test func bulkPinnedReorderingKeepsStableOrderAtScale() {
        let space = UUID(), profile = UUID(), url = URL(string: "https://example.invalid")!
        for count in [10_000, 20_000] {
            let tabs = (0..<count).map { BrowserTab(spaceID: space, profileID: profile, title: "Pin \($0)", currentURL: url, pinnedURL: url) }
            var store = TabStore(tabs: tabs)
            let start = ContinuousClock.now
            let change18 = store.reorder(tabs.last!.id, relativeTo: tabs[0].id, after: false); #expect(change18)
            let duration = start.duration(to: .now)
            #expect(store.pinnedTabs(in: space).map(\.id) == [tabs.last!.id] + tabs.dropLast().map(\.id))
            #expect(store.tabs == tabs.enumerated().map { index, tab in
                var value = tab; value.sidebarPosition = index == count - 1 ? 0 : index + 1; return value
            })
            print("TabStore reorder \(count) pins: \(duration)")
        }
    }
}
