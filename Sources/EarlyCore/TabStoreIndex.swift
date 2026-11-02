// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One derived snapshot for a TabStore value. Copies share the completed index
/// until either value changes its persisted arrays. The lock supports copies
/// being read on independent actors without putting mutable state in the model.
final class TabStoreIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TabStoreIndex?

    func value(tabs: [BrowserTab], folders: [BrowserFolder]) -> TabStoreIndex {
        lock.withLock {
            if let stored { return stored }
            let value = TabStoreIndex(tabs: tabs, folders: folders)
            stored = value
            return value
        }
    }

    func invalidate() { lock.withLock { stored = nil } }
}

struct TabStoreIndex: Sendable {
    struct Container: Hashable { let space: UUID; let parent: UUID? }
    let tabs: [UUID: Int]
    let folders: [UUID: Int]
    let foldersBySpace: [UUID: [BrowserFolder]]
    let pins: [Container: [TabStore.PinnedItem]]
    let orderedPins: [UUID: [BrowserTab]]
    let favorites: [BrowserTab]
    let today: [UUID: [BrowserTab]]
    let hierarchy: BrowserFolderHierarchy

    init(tabs: [BrowserTab], folders: [BrowserFolder]) {
        self.tabs = Dictionary(tabs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.folders = Dictionary(folders.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        foldersBySpace = Dictionary(grouping: folders, by: \.spaceID)
        hierarchy = BrowserFolderHierarchy(folders)
        var pins: [Container: [TabStore.PinnedItem]] = [:]
        for folder in folders { pins[Container(space: folder.spaceID, parent: folder.parentID), default: []].append(.folder(folder)) }
        var favorites: [BrowserTab] = [], today: [UUID: [BrowserTab]] = [:]
        for tab in tabs {
            if tab.isFavorite { favorites.append(tab) }
            else if tab.pinnedURL != nil { pins[Container(space: tab.spaceID, parent: tab.folderID), default: []].append(.tab(tab)) }
            else if tab.isOpen { today[tab.spaceID, default: []].append(tab) }
        }
        // Equal/missing positions preserve the original folders-first order.
        for (container, items) in pins where items.count > 1 {
            pins[container] = items.enumerated().sorted {
                let left = $0.element.position ?? Int.max, right = $1.element.position ?? Int.max
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        }
        self.pins = pins; self.favorites = favorites; self.today = today
        var orderedPins: [UUID: [BrowserTab]] = [:]
        for container in pins.keys where container.parent == nil {
            var result: [BrowserTab] = []
            var visited = Set<UUID>()
            func append(parent: UUID?, depth: Int) {
                guard depth <= 32 else { return }
                for item in pins[Container(space: container.space, parent: parent)] ?? [] {
                    switch item {
                    case .tab(let tab): result.append(tab)
                    case .folder(let folder):
                        if visited.insert(folder.id).inserted { append(parent: folder.id, depth: depth + 1) }
                    }
                }
            }
            append(parent: nil, depth: 0)
            orderedPins[container.space] = result
        }
        self.orderedPins = orderedPins
    }
}

/// A folder lookup and its validated depths are prepared once per metadata
/// revision. Ancestor traversal never rebuilds or scans the folders array.
public struct BrowserFolderHierarchy: Sendable {
    private let byID: [UUID: BrowserFolder]
    private let depths: [UUID: Int]
    private let heights: [UUID: Int]
    public let isValid: Bool

    public init(_ folders: [BrowserFolder]) {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byID = byID
        var depths: [UUID: Int] = [:]
        for folder in byID.values {
            var seen: Set<UUID> = [folder.id], next = folder.parentID, depth = 0
            var valid = true
            while let id = next {
                guard seen.insert(id).inserted, seen.count <= 32,
                      let ancestor = byID[id], ancestor.spaceID == folder.spaceID else { valid = false; break }
                depth += 1; next = ancestor.parentID
            }
            if valid { depths[folder.id] = depth }
        }
        self.depths = depths
        isValid = byID.count == folders.count && depths.count == folders.count && folders.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 128
        }
        var heights: [UUID: Int] = [:]
        for folder in byID.values where depths[folder.id] != nil {
            var next = folder.parentID, height = 1
            while let id = next, let ancestor = byID[id] {
                heights[id] = max(heights[id] ?? 0, height)
                height += 1; next = ancestor.parentID
            }
        }
        self.heights = heights
    }

    public func folder(_ id: UUID) -> BrowserFolder? { byID[id] }
    public func depth(of id: UUID) -> Int? { depths[id] }
    public func subtreeHeight(of id: UUID) -> Int? { depths[id].map { _ in heights[id] ?? 0 } }
    public func ancestors(of id: UUID) -> [BrowserFolder]? {
        guard depths[id] != nil, let folder = byID[id] else { return nil }
        var result: [BrowserFolder] = [], next = folder.parentID
        while let id = next, let ancestor = byID[id] {
            result.append(ancestor); next = ancestor.parentID
        }
        return result
    }
}
