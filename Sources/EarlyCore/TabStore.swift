// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Ordered metadata for one profile, independent of presentation and live views.
public struct TabStore: Equatable, Sendable {
    public enum PinnedItem: Identifiable {
        case tab(BrowserTab), folder(BrowserFolder)
        public var id: UUID {
            switch self { case .tab(let tab): tab.id; case .folder(let folder): folder.id }
        }
        var position: Int? {
            switch self { case .tab(let tab): tab.sidebarPosition; case .folder(let folder): folder.sidebarPosition }
        }
    }

    /// One sibling order for tabs AND folders. Old sessions retain their
    /// folders-first layout until a move assigns explicit positions.
    public func pinnedItems(in spaceID: UUID, parentID: UUID?) -> [PinnedItem] {
        let items = folders.filter { $0.spaceID == spaceID && $0.parentID == parentID }.map(PinnedItem.folder)
            + tabs.filter { $0.spaceID == spaceID && $0.folderID == parentID && $0.pinnedURL != nil && !$0.isFavorite }.map(PinnedItem.tab)
        return items.enumerated().sorted {
            let left = $0.element.position ?? Int.max, right = $1.element.position ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    @discardableResult
    public mutating func placePin(_ id: UUID, before target: UUID?) -> Bool {
        guard let tab = tab(id: id), tab.pinnedURL != nil, !tab.isFavorite else { return false }
        var ids = pinnedItems(in: tab.spaceID, parentID: tab.folderID).map(\.id).filter { $0 != id }
        if let target {
            guard let index = ids.firstIndex(of: target) else { return false }
            ids.insert(id, at: index)
        } else { ids.append(id) }
        assignPositions(ids)
        return true
    }

    public func section(of tab: BrowserTab) -> Section {
        tab.isFavorite ? .favorites : (tab.pinnedURL == nil ? .regular : .pinned)
    }

    public func siblingIDs(of tab: BrowserTab) -> [UUID] {
        if tab.isFavorite || tab.pinnedURL == nil { return peers(of: tab).map(\.id) }
        return pinnedItems(in: tab.spaceID, parentID: tab.folderID).map(\.id)
    }

    /// Move a tab into a section/folder and insert it before `before`, or at the end.
    @discardableResult
    public mutating func place(_ id: UUID, in section: Section, folderID: UUID? = nil, before: UUID? = nil, spaceID: UUID) -> Bool {
        var candidate = self
        guard candidate.applyPlacement(id, in: section, folderID: folderID, before: before, spaceID: spaceID) else { return false }
        self = candidate
        return true
    }

    private mutating func applyPlacement(_ id: UUID, in section: Section, folderID: UUID?, before: UUID?, spaceID: UUID) -> Bool {
        guard let source = tab(id: id) else { return false }
        guard source.isFavorite || source.spaceID == spaceID else { return false }
        if self.section(of: source) != section {
            guard move(id, to: section, in: spaceID) else { return false }
        }
        guard let tab = tab(id: id) else { return false }
        switch section {
        case .regular, .favorites:
            guard folderID == nil else { return false }
            let current = section == .favorites ? favorites.map(\.id) : todayTabs(in: spaceID).map(\.id)
            return place(id, among: current, before: before)
        case .pinned:
            if tab.folderID != folderID {
                guard moveTab(id, toFolder: folderID) else { return false }
            }
            return placePin(id, before: before)
        }
    }

    private mutating func place(_ id: UUID, among current: [UUID], before: UUID?) -> Bool {
        var ids = current.filter { $0 != id }
        if let before {
            guard let index = ids.firstIndex(of: before) else { return false }
            ids.insert(id, at: index)
        } else {
            ids.append(id)
        }
        if current == ids { return true }
        if let before { return reorder(id, relativeTo: before, after: false) }
        guard let previous = ids.dropLast().last else { return true }
        return reorder(id, relativeTo: previous, after: true)
    }

    private mutating func assignPositions(_ ids: [UUID]) {
        for (position, id) in ids.enumerated() {
            if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].sidebarPosition = position }
            else if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].sidebarPosition = position }
        }
    }
    public enum Section: String, Sendable { case regular, pinned, favorites }
    public private(set) var tabs: [BrowserTab]
    public private(set) var folders: [BrowserFolder]

    public init(tabs: [BrowserTab] = [], folders: [BrowserFolder] = []) {
        self.tabs = tabs
        self.folders = folders
    }

    public func tab(id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    mutating func moveTab(_ id: UUID, toSpace spaceID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id && !$0.isFavorite }) else { return false }
        var tab = tabs.remove(at: index)
        tab.spaceID = spaceID
        tab.folderID = nil
        tab.sidebarPosition = nil
        tabs.append(tab)
        if tab.pinnedURL != nil { _ = placePin(id, before: nil) }
        return true
    }

    /// Transfer an intact saved subtree, appending its root at the destination.
    /// Build a candidate first so a malformed branch cannot be partially moved.
    mutating func moveFolder(_ id: UUID, toSpace spaceID: UUID) -> (folderIDs: Set<UUID>, tabIDs: Set<UUID>)? {
        guard let root = folders.first(where: { $0.id == id }), root.spaceID != spaceID else { return nil }
        let children = Dictionary(grouping: folders, by: \.parentID)
        var folderIDs: Set<UUID> = []
        var pending = [id]
        while let next = pending.popLast(), folderIDs.insert(next).inserted {
            pending.append(contentsOf: (children[next] ?? []).map(\.id))
        }
        let destinationOrder = pinnedItems(in: spaceID, parentID: nil).map(\.id)
        var candidate = self
        for index in candidate.folders.indices where folderIDs.contains(candidate.folders[index].id) {
            let original = candidate.folders[index]
            guard original.spaceID == root.spaceID else { return nil }
            var moved = BrowserFolder(id: original.id, spaceID: spaceID,
                parentID: original.id == id ? nil : original.parentID, name: original.name,
                isExpanded: original.isExpanded)
            moved.sidebarPosition = original.id == id ? nil : original.sidebarPosition
            candidate.folders[index] = moved
        }
        var tabIDs: Set<UUID> = []
        for index in candidate.tabs.indices {
            guard let folder = candidate.tabs[index].folderID, folderIDs.contains(folder) else { continue }
            guard candidate.tabs[index].spaceID == root.spaceID,
                  candidate.tabs[index].pinnedURL != nil, !candidate.tabs[index].isFavorite else { return nil }
            candidate.tabs[index].spaceID = spaceID
            tabIDs.insert(candidate.tabs[index].id)
        }
        guard (try? BrowserFolder.validate(candidate.folders)) != nil else { return nil }
        candidate.assignPositions(destinationOrder + [id])
        self = candidate
        return (folderIDs, tabIDs)
    }

    mutating func deleteSpace(_ id: UUID, rehomeFavoritesTo fallback: UUID) -> Set<UUID> {
        let removed = Set(tabs.filter { $0.spaceID == id && !$0.isFavorite }.map(\.id))
        tabs.removeAll { removed.contains($0.id) }
        for index in tabs.indices where tabs[index].spaceID == id { tabs[index].spaceID = fallback }
        folders.removeAll { $0.spaceID == id }
        return removed
    }

    mutating func duplicateSavedItems(in source: UUID, to destination: UUID) {
        let originals = folders.filter { $0.spaceID == source }
        let folderIDs = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        let copies = originals.map { original in
            var copy = BrowserFolder(id: folderIDs[original.id]!, spaceID: destination,
                parentID: original.parentID.flatMap { folderIDs[$0] }, name: original.name)
            copy.sidebarPosition = original.sidebarPosition
            return copy
        }
        let pins = tabs.filter { $0.spaceID == source && $0.pinnedURL != nil && !$0.isFavorite }.map { original in
            var copy = BrowserTab(spaceID: destination, profileID: original.profileID,
                title: original.pinnedTitle ?? original.pinnedURL!.host ?? original.title,
                currentURL: original.pinnedURL!, pinnedURL: original.pinnedURL, isOpen: false,
                pinnedTitle: original.pinnedTitle, customTitle: original.customTitle)
            copy.folderID = original.folderID.flatMap { folderIDs[$0] }
            copy.sidebarPosition = original.sidebarPosition
            return copy
        }
        folders.append(contentsOf: copies)
        tabs.append(contentsOf: pins)
    }

    @discardableResult
    public mutating func move(_ id: UUID, to section: Section, in spaceID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        switch section {
        case .favorites:
            return setFavorite(id, favorite: true, in: spaceID)
        case .regular:
            return tabs[index].isFavorite ? setFavorite(id, favorite: false, in: spaceID) : setPinned(id, pinned: false)
        case .pinned:
            if tabs[index].isFavorite {
                // Keep the original pin URL/name and closed state, including
                // when the live page has navigated away from the pinned URL.
                tabs[index].isFavorite = false
                tabs[index].spaceID = spaceID
                tabs[index].folderID = nil
                tabs[index].sidebarPosition = nil
                return true
            }
            return setPinned(id, pinned: true)
        }
    }

    @discardableResult
    public mutating func rename(_ id: UUID, to name: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
        return true
    }

    public func peers(of tab: BrowserTab) -> [BrowserTab] {
        tabs.filter {
            $0.profileID == tab.profileID && $0.isFavorite == tab.isFavorite && ($0.pinnedURL != nil) == (tab.pinnedURL != nil)
                && (tab.isFavorite || $0.spaceID == tab.spaceID)
                && $0.folderID == tab.folderID
        }
    }

    @discardableResult
    public mutating func reorder(_ id: UUID, relativeTo targetID: UUID, after: Bool) -> Bool {
        guard id != targetID, let source = tab(id: id),
              let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        if source.pinnedURL != nil && !source.isFavorite {
            let siblings = pinnedItems(in: source.spaceID, parentID: source.folderID).map(\.id).filter { $0 != id }
            guard let targetIndex = siblings.firstIndex(of: targetID) else { return false }
            let next = after ? siblings.dropFirst(targetIndex + 1).first : targetID
            return placePin(id, before: next)
        }
        guard peers(of: source).contains(where: { $0.id == targetID }) else { return false }
        let moved = tabs.remove(at: index)
        let destination = tabs.firstIndex(where: { $0.id == targetID })!
        tabs.insert(moved, at: destination + (after ? 1 : 0))
        return true
    }

    public func openTabs(in spaceID: UUID) -> [BrowserTab] {
        // Keyboard selection and close-neighbour selection follow sidebar order.
        favorites.filter(\.isOpen) + pinnedTabs(in: spaceID).filter(\.isOpen) + todayTabs(in: spaceID)
    }

    public var favorites: [BrowserTab] { tabs.filter(\.isFavorite) }

    public func pinnedTabs(in spaceID: UUID) -> [BrowserTab] {
        func ordered(parent: UUID?, depth: Int) -> [BrowserTab] {
            guard depth <= 32 else { return [] }
            return pinnedItems(in: spaceID, parentID: parent).flatMap { item -> [BrowserTab] in
                switch item {
                case .tab(let tab): return [tab]
                case .folder(let folder): return ordered(parent: folder.id, depth: depth + 1)
                }
            }
        }
        return ordered(parent: nil, depth: 0)
    }

    public func todayTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID && $0.pinnedURL == nil && !$0.isFavorite && $0.isOpen }
    }

    @discardableResult
    public mutating func setPinned(_ id: UUID, pinned: Bool) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              !tabs[index].isFavorite,
              (tabs[index].pinnedURL != nil) != pinned else { return false }
        if pinned {
            guard tabs[index].isOpen else { return false }
            tabs[index].pinnedURL = tabs[index].currentURL
            tabs[index].pinnedTitle = savedTitle(for: tabs[index])
        } else {
            tabs[index].folderID = nil
            tabs[index].pinnedURL = nil
            tabs[index].pinnedTitle = nil
            // A closed pin becomes an unloaded Today tab, not orphaned metadata.
            // The runtime owner still loads only on explicit selection.
            tabs[index].isOpen = true
        }
        tabs[index].sidebarPosition = nil
        return true
    }

    /// Favorites reuse pin lifecycle and identity, but are visible in every space.
    /// Removing one places a regular tab in the current space, without loading it.
    @discardableResult
    public mutating func setFavorite(_ id: UUID, favorite: Bool, in spaceID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].isFavorite != favorite else { return false }
        if favorite, tabs[index].pinnedURL == nil {
            guard setPinned(id, pinned: true) else { return false }
        }
        tabs[index].isFavorite = favorite
        tabs[index].folderID = nil
        tabs[index].sidebarPosition = nil
        if !favorite {
            tabs[index].spaceID = spaceID
            tabs[index].pinnedURL = nil
            tabs[index].pinnedTitle = nil
            // A closed favorite becomes an unloaded regular tab, like unpinning.
            tabs[index].isOpen = true
        }
        return true
    }

    public mutating func insert(_ tab: BrowserTab, at position: Int? = nil) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.insert(tab, at: min(max(position ?? tabs.count, 0), tabs.count))
    }

    @discardableResult
    public mutating func createFolder(name: String, parentID: UUID?, spaceID: UUID) -> UUID? {
        guard canCreateFolder(in: parentID, spaceID: spaceID) else { return nil }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        let folder = BrowserFolder(spaceID: spaceID, parentID: parentID, name: name)
        let candidate = folders + [folder]
        guard (try? BrowserFolder.validate(candidate)) != nil else { return nil }
        folders = candidate
        // Reveal the new child through every ancestor, while keeping the child
        // itself collapsed. Validation guarantees a finite, same-space path.
        var parent = parentID
        while let id = parent, let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].isExpanded = true
            parent = folders[index].parentID
        }
        return folder.id
    }

    public func canCreateFolder(in parentID: UUID?, spaceID: UUID) -> Bool {
        guard let parentID else { return true }
        guard folders.contains(where: { $0.id == parentID && $0.spaceID == spaceID }),
              let depth = BrowserFolder.nestingDepth(of: parentID, in: folders) else { return false }
        return depth < BrowserFolder.maximumNestingDepth
    }

    @discardableResult
    public mutating func renameFolder(_ id: UUID, to name: String) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[index].name = name
        return true
    }

    /// Delete a whole subtree, including closed pins. Unlike closing a tab,
    /// this removes its saved record rather than leaving a persistent pin.
    @discardableResult
    public mutating func deleteFolder(_ id: UUID) -> (folderIDs: Set<UUID>, tabIDs: Set<UUID>)? {
        guard folders.contains(where: { $0.id == id }) else { return nil }
        let children = Dictionary(grouping: folders, by: \.parentID)
        var folderIDs: Set<UUID> = []
        var pending = [id]
        while let next = pending.popLast(), folderIDs.insert(next).inserted {
            pending.append(contentsOf: (children[next] ?? []).map(\.id))
        }
        let tabIDs = Set(tabs.filter { tab in
            tab.folderID.map { folderIDs.contains($0) } ?? false
        }.map(\.id))
        tabs.removeAll { tabIDs.contains($0.id) }
        folders.removeAll { folderIDs.contains($0.id) }
        return (folderIDs, tabIDs)
    }

    public func canMoveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = folders
        candidate[index].parentID = parentID
        guard (try? BrowserFolder.validate(candidate)) != nil else { return false }
        // A subtree move must fit every descendant, not just its root. Unrelated
        // legacy branches do not prevent users reorganizing shallower folders.
        guard let rootDepth = BrowserFolder.nestingDepth(of: id, in: candidate) else { return false }
        let children = Dictionary(grouping: folders, by: \.parentID)
        var pending = [(id, rootDepth)]
        while let (next, depth) = pending.popLast() {
            guard depth <= BrowserFolder.maximumNestingDepth else { return false }
            pending.append(contentsOf: (children[next] ?? []).map { ($0.id, depth + 1) })
        }
        return true
    }

    @discardableResult
    public mutating func moveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard canMoveFolder(id, to: parentID), let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[index].parentID = parentID
        folders[index].sidebarPosition = nil
        return true
    }

    public mutating func toggleFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        setFolderExpanded(id, expanded: !folders[index].isExpanded)
    }

    /// Commit folder nesting and mixed tab/folder ordering as one atomic move.
    @discardableResult
    public mutating func placeFolder(_ id: UUID, in parentID: UUID?, before: UUID?) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }), canMoveFolder(id, to: parentID) else { return false }
        var ids = pinnedItems(in: folder.spaceID, parentID: parentID).map(\.id).filter { $0 != id }
        if let before {
            guard let index = ids.firstIndex(of: before) else { return false }
            ids.insert(id, at: index)
        } else { ids.append(id) }
        guard moveFolder(id, to: parentID) else { return false }
        assignPositions(ids)
        var parent = parentID
        while let id = parent, let folder = folders.first(where: { $0.id == id }) {
            setFolderExpanded(id, expanded: true)
            parent = folder.parentID
        }
        return true
    }

    public mutating func setFolderExpanded(_ id: UUID, expanded: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isExpanded = expanded
    }

    @discardableResult
    public mutating func moveTab(_ id: UUID, toFolder folderID: UUID?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].isFavorite else { return false }
        if let folderID {
            guard let folder = folders.first(where: { $0.id == folderID }), folder.spaceID == tabs[index].spaceID else { return false }
            if tabs[index].pinnedURL == nil { guard setPinned(id, pinned: true) else { return false } }
            // Reveal the destination path, without selecting or reloading the page.
            var parent: UUID? = folderID
            while let id = parent, let position = folders.firstIndex(where: { $0.id == id }) {
                folders[position].isExpanded = true
                parent = folders[position].parentID
            }
        }
        if tabs[index].folderID != folderID { tabs[index].sidebarPosition = nil }
        tabs[index].folderID = folderID
        return true
    }

    public mutating func recordActivation(_ id: UUID, at date: Date) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].recordActivation(at: date)
    }

    public mutating func reopen(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isOpen = true
    }

    @discardableResult
    public mutating func update(_ id: UUID, url: URL? = nil, title: String? = nil) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let before = tabs[index]
        if let url { tabs[index].currentURL = url }
        if let title, !title.isEmpty { tabs[index].title = String(title.prefix(512)) }
        // Old sessions and pins made before a page finished loading have no
        // saved name. Learn it only from the original page, never a subpage.
        if title != nil, tabs[index].pinnedTitle == nil,
           tabs[index].currentURL == tabs[index].pinnedURL {
            tabs[index].pinnedTitle = savedTitle(for: tabs[index])
        }
        return before != tabs[index]
    }

    private func savedTitle(for tab: BrowserTab) -> String? {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != tab.currentURL.host,
              title != tab.currentURL.absoluteString else { return nil }
        return String(title.prefix(512))
    }

    @discardableResult
    public mutating func resetPinnedLocation(_ id: UUID) -> URL? {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let url = tabs[index].pinnedURL else { return nil }
        tabs[index].currentURL = url
        tabs[index].title = tabs[index].pinnedTitle ?? url.host ?? url.absoluteString
        return url
    }

    /// Closing a pin resets its address and unloads it, preserving its identity.
    /// Prefer the next open neighbor, then the previous one, in this space only.
    @discardableResult
    public mutating func close(id: UUID, in spaceID: UUID? = nil) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.isOpen }) else {
            return nil
        }
        let tab = tabs[index]
        let candidates = openTabs(in: spaceID ?? tab.spaceID)
        guard let openIndex = candidates.firstIndex(where: { $0.id == id }) else { return nil }
        let nextID = candidates.dropFirst(openIndex + 1).first?.id
            ?? candidates.prefix(openIndex).last?.id
        if tab.pinnedURL != nil {
            tabs[index].isOpen = false
            resetPinnedLocation(id)
        } else {
            tabs.remove(at: index)
        }
        return nextID
    }
}
