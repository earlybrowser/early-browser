// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import Testing
@testable import EarlyCore

struct SidebarDragPlacementTests {
    private func ids(in section: TabStore.Section, store: TabStore, space: UUID, parent: UUID? = nil) -> [UUID] {
        switch section {
        case .favorites: store.favorites.map(\.id)
        case .pinned: store.pinnedItems(in: space, parentID: parent).map(\.id)
        case .regular: store.todayTabs(in: space).map(\.id)
        }
    }

    @Test(arguments: [TabStore.Section.regular, .pinned, .favorites], [TabStore.Section.regular, .pinned, .favorites])
    func everySectionPairCommitsThePreviewOrderAtTheStartMiddleAndEnd(source: TabStore.Section, destination: TabStore.Section) throws {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com/live")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Source", currentURL: url,
            pinnedURL: source == .regular ? nil : url, isFavorite: source == .favorites)
        let peers = (0..<3).map {
            BrowserTab(spaceID: space, profileID: profile, title: "Peer \($0)", currentURL: url,
                pinnedURL: destination == .regular ? nil : url, isFavorite: destination == .favorites)
        }
        for index in 0...peers.count {
            var store = TabStore(tabs: [tab] + peers)
            var order = ids(in: destination, store: store, space: space)
            let foreign = !order.contains(tab.id)
            if foreign { order.append(tab.id) }
            let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
            let frames = destination == .favorites ? SidebarReorderLayout.favoriteFrames(count: order.count, in: bounds)
                : order.indices.map { CGRect(x: 0, y: CGFloat($0) * 38, width: 300, height: 34) }
            let slots = zip(order, frames).map { SidebarReorderLayout.Slot(id: $0.0, frame: $0.1) }
            let others = slots.filter { $0.id != tab.id }
            let point: CGPoint
            if destination == .favorites {
                let x = index < others.count ? others[index].frame.midX - 1 : others.last!.frame.maxX - 1
                point = CGPoint(x: x, y: 20)
            } else {
                let y = index < others.count ? others[index].frame.midY - 1 : others.last!.frame.maxY + 1
                point = CGPoint(x: 100, y: y)
            }
            let layout = SidebarReorderLayout(source: tab.id, slots: slots, bounds: bounds,
                grid: destination == .favorites, foreign: foreign)
            let preview = layout.order(at: point)
            if let insertion = layout.insertion(at: point) {
                let placed = store.place(tab.id, in: destination, before: insertion.before, spaceID: space)
                #expect(placed)
            }
            #expect(ids(in: destination, store: store, space: space) == preview)
            #expect(preview.firstIndex(of: tab.id) == index)
            #expect(store.tabs.filter { $0.id == tab.id }.count == 1)
            #expect(store.tab(id: tab.id)?.currentURL == url)
            if source != destination { #expect(!ids(in: source, store: store, space: space).contains(tab.id)) }
        }
    }

    @Test(arguments: [TabStore.Section.regular, .pinned, .favorites], [TabStore.Section.regular, .pinned, .favorites])
    func droppingIntoAnEmptySectionPreservesOneIdentity(source: TabStore.Section, destination: TabStore.Section) {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Only tab", currentURL: url,
            pinnedURL: source == .regular ? nil : url, isFavorite: source == .favorites)
        var store = TabStore(tabs: [tab])
        let placed = store.place(tab.id, in: destination, spaceID: space)
        #expect(placed && ids(in: destination, store: store, space: space) == [tab.id])
        #expect(store.tabs.count == 1 && store.tab(id: tab.id)?.currentURL == url)
    }

    @Test func nestedFolderDropsAndLiftOutCommitOnlyTheRequestedSiblingOrder() throws {
        let profile = UUID(), space = UUID(), url = URL(string: "https://example.com")!
        let root = BrowserFolder(spaceID: space, name: "Root")
        let child = BrowserFolder(spaceID: space, parentID: root.id, name: "Child")
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Source", currentURL: url)
        var store = TabStore(tabs: [tab], folders: [root, child])
        let nested = store.place(tab.id, in: .pinned, folderID: child.id, spaceID: space)
        #expect(nested && ids(in: .pinned, store: store, space: space, parent: child.id) == [tab.id])
        let ancestorsExpanded = store.folders.allSatisfy(\.isExpanded)
        #expect(ancestorsExpanded)
        let lifted = store.place(tab.id, in: .pinned, before: root.id, spaceID: space)
        #expect(lifted && ids(in: .pinned, store: store, space: space) == [tab.id, root.id])
        #expect(store.tab(id: tab.id)?.folderID == nil && store.tabs.count == 1)
        let saved = store
        let invalid = store.place(tab.id, in: .pinned, folderID: child.id, before: UUID(), spaceID: space)
        #expect(!invalid && store == saved, "Invalid drop must not emit an intermediate conversion/order")
        try BrowserFolder.validate(store.folders)
    }
}
