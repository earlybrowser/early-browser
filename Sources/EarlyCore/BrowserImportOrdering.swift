// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Legacy items without positions sort last in TabStore. Merely choosing a
/// larger numeric position for new items would put imports before those items.
/// Normalize affected sibling orders once, preserving their exact visual order.
enum BrowserImportOrdering {
    static func append(in session: inout BrowserSession, after original: BrowserSession?, imported: Set<UUID>) {
        func groups(_ source: BrowserSession) -> [String: [TabStore.PinnedItem]] {
            let items = source.folders.map(TabStore.PinnedItem.folder)
                + source.tabs.filter { $0.pinnedURL != nil && !$0.isFavorite }.map(TabStore.PinnedItem.tab)
            return Dictionary(grouping: items) { item in
                switch item {
                case .folder(let value): value.spaceID.uuidString + (value.parentID?.uuidString ?? "root")
                case .tab(let value): value.spaceID.uuidString + (value.folderID?.uuidString ?? "root")
                }
            }
        }
        func ordered(_ values: [TabStore.PinnedItem]) -> [TabStore.PinnedItem] {
            values.enumerated().sorted {
                ($0.element.position ?? Int.max, $0.offset) < ($1.element.position ?? Int.max, $1.offset)
            }.map(\.element)
        }
        let old = original.map(groups) ?? [:]
        var positions: [UUID: Int] = [:]
        for (key, values) in groups(session) {
            let additions = values.filter { imported.contains($0.id) }
            guard !additions.isEmpty else { continue }
            let items = ordered(old[key] ?? []) + ordered(additions)
            for (index, item) in items.enumerated() { positions[item.id] = index }
        }
        for index in session.tabs.indices {
            if let value = positions[session.tabs[index].id] { session.tabs[index].sidebarPosition = value }
        }
        for index in session.folders.indices {
            if let value = positions[session.folders[index].id] { session.folders[index].sidebarPosition = value }
        }
    }

    static func synchronizePositions(from root: BrowserSession, to window: inout BrowserSession) {
        let positions = Dictionary(uniqueKeysWithValues: root.tabs.map { ($0.id, $0.sidebarPosition) })
        for index in window.tabs.indices where window.tabs[index].pinnedURL != nil {
            if let value = positions[window.tabs[index].id] { window.tabs[index].sidebarPosition = value }
        }
    }
}

public extension BrowserImportBatch {
    func adjustedPositions(in workspace: BrowserWorkspace) -> Self {
        let tabs = Dictionary(uniqueKeysWithValues: workspace.sessions.flatMap(\.tabs).map { ($0.id, $0.sidebarPosition) })
        let folders = Dictionary(uniqueKeysWithValues: workspace.sessions.flatMap(\.folders).map { ($0.id, $0.sidebarPosition) })
        var copy = self
        for index in copy.tabs.indices { copy.tabs[index].sidebarPosition = tabs[copy.tabs[index].id] ?? nil }
        for index in copy.folders.indices { copy.folders[index].sidebarPosition = folders[copy.folders[index].id] ?? nil }
        return copy
    }
}
