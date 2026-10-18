// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

/// One coordinator per browser window. UI actions all enter through this type.
@MainActor @Observable
public final class BrowserCoordinator {
    public private(set) var tabStore: TabStore
    public private(set) var activeSpaceID: UUID
    public private(set) var spaces: [BrowserSpace]
    public private(set) var content: BrowserContentPresentation = .empty
    public private(set) var commandBar: CommandBarPresentation?
    public private(set) var commandBarFocusRequest = 0
    public let profileID: UUID
    public private(set) var recentlyClosed: [ClosedTab]
    private var selectionBySpace: [UUID: UUID]

    public init(
        startup: StartupContext,
        activeSpaceID: UUID = UUID(),
        tabStore: TabStore = TabStore(),
        selectionBySpace: [UUID: UUID] = [:],
        profileID: UUID = UUID(),
        recentlyClosed: [ClosedTab] = [],
        spaces: [BrowserSpace]? = nil
    ) {
        self.activeSpaceID = activeSpaceID
        self.tabStore = tabStore
        self.selectionBySpace = selectionBySpace
        self.profileID = profileID
        self.recentlyClosed = Array(recentlyClosed.suffix(20))
        self.spaces = spaces ?? BrowserSpace.migrated(profileID: profileID, activeID: activeSpaceID,
            tabs: tabStore.tabs, folders: tabStore.folders, selection: selectionBySpace, closed: recentlyClosed)
        for folder in tabStore.folders {
            self.tabStore.setFolderExpanded(folder.id, expanded: false)
        }
        pruneSelections()
        restoreSelection()
        if case .firstLaunch = startup, tabStore.tabs.isEmpty {
            presentCommandBar(.newTab)
        }
    }

    public func presentCommandBar(_ intent: CommandBarIntent) {
        var query = ""
        if intent == .navigateCurrentTab, case .web(let id) = content {
            query = tabStore.tab(id: id)?.currentURL.absoluteString ?? ""
        }
        commandBar = CommandBarPresentation(intent: intent, query: query)
        commandBarFocusRequest += 1
    }

    public func updateQuery(_ query: String) {
        commandBar?.query = query
    }

    public func dismissCommandBar() {
        commandBar = nil
    }

    /// Resolve/validate this request before mutating metadata or allocating views.
    public func navigationRequest() -> NavigationRequest? {
        guard let commandBar, commandBar.intent != .commandSearch else { return nil }
        let query = commandBar.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let target: NavigationRequest.Target
        if commandBar.intent == .navigateCurrentTab, case .web(let id) = content {
            target = .currentTab(id)
        } else {
            target = .newTab(spaceID: activeSpaceID)
        }
        return NavigationRequest(query: query, target: target)
    }

    public func selectOpenTab(_ id: UUID) {
        guard let tab = tabStore.tab(id: id), tab.isOpen,
              canAccess(tab) else { return }
        selectionBySpace[activeSpaceID] = id
        content = .web(tabID: id)
        dismissCommandBar()
    }

    /// Sidebar selection can reopen a persistent pin. Never duplicate its record.
    @discardableResult
    public func openTab(_ id: UUID) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              tab.isOpen || tab.pinnedURL != nil else { return false }
        tabStore.reopen(id)
        recentlyClosed.removeAll { $0.tab.id == id }
        selectOpenTab(id)
        return true
    }

    @discardableResult
    public func setPinned(_ id: UUID, pinned: Bool) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              tabStore.setPinned(id, pinned: pinned) else { return false }
        // Do not let a stale closure later restore the pre-unpin state.
        recentlyClosed.removeAll { $0.tab.id == id }
        return true
    }

    @discardableResult
    public func renameTab(_ id: UUID, to name: String) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab), tabStore.rename(id, to: name) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        return true
    }

    @discardableResult
    public func reorderTab(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard let source = tabStore.tab(id: id), canAccess(source) else { return false }
        if let destination = tabStore.tab(id: target) {
            guard canAccess(destination) else { return false }
        } else {
            guard folders.contains(where: { $0.id == target }) else { return false }
        }
        return tabStore.reorder(id, relativeTo: target, after: after)
    }

    @discardableResult
    public func setFavorite(_ id: UUID, favorite: Bool) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              tabStore.setFavorite(id, favorite: favorite, in: activeSpaceID) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        if !favorite {
            // A demoted favorite now belongs only to this space. Other spaces
            // must not restore stale selections pointing to an inaccessible tab.
            for space in Array(selectionBySpace.keys) where space != activeSpaceID && selectionBySpace[space] == id {
                selectionBySpace[space] = nil
            }
        }
        return true
    }

    /// Reset is an explicit navigation, including when the pin was closed.
    @discardableResult
    public func resetPinnedTab(_ id: UUID) -> URL? {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              let url = tab.pinnedURL else { return nil }
        tabStore.resetPinnedLocation(id)
        _ = openTab(id)
        return url
    }

    /// Returns the runtime identity the owner must release, if anything closed.
    @discardableResult
    public func closeActiveTab() -> UUID? {
        // With zero tabs, Command+W is a true no-op, including a visible bar.
        guard case .web(let id) = content else { return nil }
        return closeTab(id)
    }

    public var activeTabID: UUID? {
        if case .web(let id) = content { return id }
        return nil
    }

    public var session: BrowserSession {
        BrowserSession(profileID: profileID, activeSpaceID: activeSpaceID,
                       tabs: tabStore.tabs, selectionBySpace: selectionBySpace,
                       recentlyClosed: recentlyClosed, folders: tabStore.folders, spaces: spaces)
    }

    public var folders: [BrowserFolder] { tabStore.folders.filter { $0.spaceID == activeSpaceID } }

    /// Replace a window's metadata after an atomic workspace operation. Runtime
    /// views are owned by its profile's manager and are reconciled by the caller.
    @discardableResult
    public func applySession(_ session: BrowserSession, using input: NavigationInput = NavigationInput()) -> Bool {
        guard session.profileID == profileID, (try? session.validate(using: input)) != nil else { return false }
        tabStore = TabStore(tabs: session.tabs, folders: session.folders)
        spaces = session.spaces
        activeSpaceID = session.activeSpaceID
        selectionBySpace = session.selectionBySpace
        recentlyClosed = session.recentlyClosed
        pruneSelections()
        restoreSelection()
        dismissCommandBar()
        return true
    }

    /// Share saved organization, never another window's Today tabs, selection,
    /// open/closed state, or live page URL. Call only for the same profile.
    public func synchronizeSavedItems(from source: BrowserSession) {
        guard source.profileID == profileID else { return }
        // Runtime snapshots may use an app-approved test/custom scheme; URL
        // policy is checked by persistence, not by organization sharing.
        guard (try? BrowserSpace.validate(source.spaces, profileID: profileID)) != nil else { return }
        let previousSpace = activeSpaceID
        let previousIndex = spaces.firstIndex { $0.id == activeSpaceID } ?? 0
        spaces = source.spaces
        let spaceIDs = Set(spaces.map(\.id))
        if !spaceIDs.contains(activeSpaceID) {
            activeSpaceID = spaces[min(max(previousIndex - 1, 0), spaces.count - 1)].id
            dismissCommandBar()
        }
        let saved = source.tabs.filter { $0.pinnedURL != nil }
        let savedIDs = Set(saved.map(\.id))
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(uniqueKeysWithValues: tabStore.tabs.map { ($0.id, $0) })
        var regular = tabStore.tabs.filter {
            $0.pinnedURL == nil && !savedIDs.contains($0.id) && spaceIDs.contains($0.spaceID)
        }
        // Unpinning is shared, but a live copy in this window must survive.
        let unpinnedIDs = Set(source.tabs.filter { $0.pinnedURL == nil }.map(\.id))
        for var tab in tabStore.tabs where tab.pinnedURL != nil && !savedIDs.contains(tab.id) && unpinnedIDs.contains(tab.id) && tab.isOpen && spaceIDs.contains(tab.spaceID) {
            tab.pinnedURL = nil
            tab.pinnedTitle = nil
            tab.isFavorite = false
            tab.folderID = nil
            tab.sidebarPosition = nil
            regular.append(tab)
        }
        let shared = saved.map { record in
            var tab = record
            if let local = localByID[record.id] {
                tab.currentURL = local.currentURL
                tab.title = local.title
                tab.isOpen = local.isOpen
            } else {
                tab.currentURL = record.pinnedURL!
                tab.title = record.pinnedTitle ?? record.title
                tab.isOpen = false
            }
            return tab
        }
        let expanded = Dictionary(uniqueKeysWithValues: tabStore.folders.map { ($0.id, $0.isExpanded) })
        let folders = source.folders.map { record in
            var folder = record
            folder.isExpanded = expanded[folder.id] ?? false
            return folder
        }
        tabStore = TabStore(tabs: shared + regular, folders: folders)
        let folderIDs = Set(folders.map(\.id))
        // Do not resurrect deleted saved items or references to deleted folders.
        recentlyClosed.removeAll { closed in
            !spaceIDs.contains(closed.tab.spaceID) ||
            (closed.tab.pinnedURL != nil && !savedIDs.contains(closed.tab.id)) ||
            savedByID[closed.tab.id].map {
                $0.spaceID != closed.tab.spaceID || $0.folderID != closed.tab.folderID || $0.isFavorite != closed.tab.isFavorite
            } == true ||
            closed.tab.folderID.map { !folderIDs.contains($0) } == true
        }
        // Shared pins may move to a different Space; a local live view keeps
        // its identity, but its old Space must no longer select it.
        pruneSelections()
        restoreSelection()
        if previousSpace != activeSpaceID { dismissCommandBar() }
    }

    @discardableResult
    public func moveTab(_ id: UUID, to section: TabStore.Section) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              tabStore.move(id, to: section, in: activeSpaceID) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        if section != .favorites {
            for space in Array(selectionBySpace.keys) where space != activeSpaceID && selectionBySpace[space] == id {
                selectionBySpace[space] = nil
            }
        }
        return true
    }

    @discardableResult
    public func placeTab(_ id: UUID, in section: TabStore.Section, folderID: UUID? = nil, before: UUID? = nil) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab),
              tabStore.place(id, in: section, folderID: folderID, before: before, spaceID: activeSpaceID) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        if section != .favorites {
            for space in Array(selectionBySpace.keys) where space != activeSpaceID && selectionBySpace[space] == id {
                selectionBySpace[space] = nil
            }
        }
        return true
    }

    @discardableResult
    public func createFolder(name: String, parentID: UUID? = nil) -> UUID? {
        tabStore.createFolder(name: name, parentID: parentID, spaceID: activeSpaceID)
    }

    @discardableResult
    public func renameFolder(_ id: UUID, to name: String) -> Bool {
        guard folders.contains(where: { $0.id == id }) else { return false }
        return tabStore.renameFolder(id, to: name)
    }

    @discardableResult
    public func deleteFolder(_ id: UUID) -> Set<UUID>? {
        guard folders.contains(where: { $0.id == id }) else { return nil }
        let previousActive = activeTabID
        let previousOrder = tabStore.openTabs(in: activeSpaceID).map(\.id)
        guard let removed = tabStore.deleteFolder(id) else { return nil }
        // Reopen Closed Tab must not resurrect deleted folder records or keep
        // dangling references that make the next saved session invalid.
        recentlyClosed.removeAll {
            removed.tabIDs.contains($0.tab.id)
                || ($0.tab.folderID.map { removed.folderIDs.contains($0) } ?? false)
        }
        for space in Array(selectionBySpace.keys) {
            if let selected = selectionBySpace[space], removed.tabIDs.contains(selected) {
                selectionBySpace[space] = nil
            }
        }
        if let previousActive, removed.tabIDs.contains(previousActive) {
            let index = previousOrder.firstIndex(of: previousActive) ?? 0
            let next = previousOrder.dropFirst(index + 1).first { !removed.tabIDs.contains($0) }
                ?? previousOrder.prefix(index).last { !removed.tabIDs.contains($0) }
            selectionBySpace[activeSpaceID] = next
            content = next.map { .web(tabID: $0) } ?? .empty
            dismissCommandBar()
        }
        return removed.tabIDs
    }

    @discardableResult
    public func moveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard folders.contains(where: { $0.id == id }) else { return false }
        return tabStore.moveFolder(id, to: parentID)
    }

    @discardableResult
    public func placeFolder(_ id: UUID, in parentID: UUID?, before: UUID?) -> Bool {
        guard folders.contains(where: { $0.id == id }) else { return false }
        return tabStore.placeFolder(id, in: parentID, before: before)
    }

    public func toggleFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        tabStore.toggleFolder(id)
    }

    public func setFolderExpanded(_ id: UUID, expanded: Bool) {
        guard folders.contains(where: { $0.id == id }) else { return }
        tabStore.setFolderExpanded(id, expanded: expanded)
    }

    @discardableResult
    public func moveTab(_ id: UUID, toFolder folderID: UUID?) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab), tabStore.moveTab(id, toFolder: folderID) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        return true
    }

    @discardableResult
    public func openBackgroundTab(to url: URL) -> UUID {
        let tab = BrowserTab(spaceID: activeSpaceID, profileID: profileID,
                             title: url.host ?? url.absoluteString, currentURL: url)
        tabStore.insert(tab)
        // Do not alter selection, command-bar state, or keyboard focus.
        return tab.id
    }

    @discardableResult
    public func navigate(to url: URL, target: NavigationRequest.Target) -> UUID? {
        let id: UUID
        switch target {
        case .currentTab(let existing):
            guard let tab = tabStore.tab(id: existing), tab.isOpen,
                  canAccess(tab) else { return nil }
            id = existing
            tabStore.update(id, url: url)
        case .newTab(let space):
            guard space == activeSpaceID else { return nil }
            let tab = BrowserTab(spaceID: space, profileID: profileID,
                                 title: url.host ?? url.absoluteString, currentURL: url)
            id = tab.id
            tabStore.insert(tab)
        }
        selectOpenTab(id)
        return id
    }

    @discardableResult
    public func updateMetadata(_ id: UUID, url: URL?, title: String?) -> Bool {
        // A late page callback must not overwrite a closed pin's reset URL.
        guard tabStore.tab(id: id)?.isOpen == true else { return false }
        return tabStore.update(id, url: url, title: title)
    }

    @discardableResult
    public func closeTab(_ id: UUID) -> UUID? {
        guard let index = tabStore.tabs.firstIndex(where: { $0.id == id && $0.isOpen }) else { return nil }
        let tab = tabStore.tabs[index]
        let nextID = tabStore.close(id: id, in: tab.isFavorite ? activeSpaceID : tab.spaceID)
        recentlyClosed.removeAll { $0.tab.id == id }
        // History must use the reset pin too, including persisted reopen paths.
        recentlyClosed.append(ClosedTab(tab: tabStore.tab(id: id) ?? tab, position: index))
        recentlyClosed = Array(recentlyClosed.suffix(20))
        for space in Array(selectionBySpace.keys) where selectionBySpace[space] == id {
            selectionBySpace[space] = space == (tab.isFavorite ? activeSpaceID : tab.spaceID) ? nextID : nil
        }
        if activeTabID == id {
            content = nextID.map { .web(tabID: $0) } ?? .empty
            dismissCommandBar()
        }
        return id
    }

    @discardableResult
    public func reopenLastTab() -> UUID? {
        guard var closed = recentlyClosed.popLast() else { return nil }
        closed.tab.isOpen = true
        if tabStore.tab(id: closed.tab.id) != nil {
            tabStore.reopen(closed.tab.id)
        } else {
            tabStore.insert(closed.tab, at: closed.position)
        }
        if !closed.tab.isFavorite { activeSpaceID = closed.tab.spaceID }
        selectOpenTab(closed.tab.id)
        return closed.tab.id
    }

    public var activeSpace: BrowserSpace? { spaces.first { $0.id == activeSpaceID } }

    /// Change only catalog order. UUID-based selection, live tabs, history and
    /// pending command-bar intent remain untouched.
    @discardableResult
    public func reorderSpace(_ id: UUID, before beforeID: UUID?) -> Bool {
        guard id != beforeID,
              let source = spaces.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
              beforeID == nil || spaces.contains(where: { $0.id == beforeID && $0.profileID == profileID }) else { return false }
        var reordered = spaces
        let space = reordered.remove(at: source)
        let destination = beforeID.flatMap { before in reordered.firstIndex { $0.id == before } } ?? reordered.count
        reordered.insert(space, at: destination)
        guard reordered != spaces else { return false }
        spaces = reordered
        return true
    }

    @discardableResult
    public func createSpace(name: String, color: BrowserSpace.Color = .blue, icon: SpaceIcon? = nil) -> UUID? {
        guard let name = BrowserSpace.normalizedName(name) else { return nil }
        let space = BrowserSpace(profileID: profileID, name: name, color: color, icon: icon)
        spaces.append(space)
        return space.id
    }

    @discardableResult
    public func editSpace(_ id: UUID, name: String, color: BrowserSpace.Color) -> Bool {
        editSpace(id, name: name, color: color, icon: spaces.first { $0.id == id }?.icon)
    }

    @discardableResult
    public func editSpace(_ id: UUID, name: String, color: BrowserSpace.Color, icon: SpaceIcon?) -> Bool {
        guard let name = BrowserSpace.normalizedName(name),
              let index = spaces.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { return false }
        spaces[index].name = name
        spaces[index].color = color
        spaces[index].icon = icon
        return true
    }

    /// Copy saved organization, not Today tabs, shared Favorites, live page
    /// state, or selection. All copies are closed and receive fresh identities.
    @discardableResult
    public func duplicateSpace(_ id: UUID, name: String) -> UUID? {
        guard let source = spaces.first(where: { $0.id == id && $0.profileID == profileID }),
              let name = BrowserSpace.normalizedName(name) else { return nil }
        let copy = BrowserSpace(profileID: profileID, name: name, color: source.color, icon: source.icon)
        tabStore.duplicateSavedItems(in: id, to: copy.id)
        spaces.append(copy)
        return copy.id
    }

    /// Explicitly destructive: remove this Space's contents/history in every
    /// window. Favorites are profile-wide and are rehomed without duplication.
    /// The owner discards returned live-page identities. The last Space stays.
    @discardableResult
    public func deleteSpace(_ id: UUID) -> Set<UUID>? {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { return nil }
        let fallback = spaces[index == 0 ? 1 : index - 1].id
        let removed = tabStore.deleteSpace(id, rehomeFavoritesTo: fallback)
        spaces.remove(at: index)
        recentlyClosed.removeAll { !$0.tab.isFavorite && $0.tab.spaceID == id }
        for index in recentlyClosed.indices where recentlyClosed[index].tab.spaceID == id {
            recentlyClosed[index].tab.spaceID = fallback
        }
        if activeSpaceID == id {
            activeSpaceID = fallback
            dismissCommandBar()
        }
        pruneSelections()
        restoreSelection()
        return removed
    }

    /// Move within this profile, preserving URL, pin state, open state and ID.
    /// Append at the destination's top level. UI moves can follow the item;
    /// closed pins stay closed even when following them to their new Space.
    @discardableResult
    public func moveTab(_ id: UUID, toSpace spaceID: UUID, follow: Bool = false) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID }),
              let tab = tabStore.tab(id: id), tab.profileID == profileID,
              !tab.isFavorite, tab.spaceID != spaceID else { return false }
        let wasActive = activeTabID == id
        let oldOrder = tabStore.openTabs(in: tab.spaceID).map(\.id)
        guard tabStore.moveTab(id, toSpace: spaceID) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        pruneSelections()
        if wasActive {
            let index = oldOrder.firstIndex(of: id) ?? 0
            let next = oldOrder.dropFirst(index + 1).first ?? oldOrder.prefix(index).last
            selectionBySpace[activeSpaceID] = next
            dismissCommandBar()
        }
        restoreSelection()
        if follow {
            _ = switchSpace(to: spaceID)
            if tab.isOpen { selectOpenTab(id) }
        }
        return true
    }

    /// Move the folder and all descendants without changing identities, live
    /// URLs or open/closed state. Following keeps a selected tab in the moved
    /// subtree; otherwise it retains the destination's existing selection.
    @discardableResult
    public func moveFolder(_ id: UUID, toSpace spaceID: UUID, follow: Bool = false) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID }),
              let folder = tabStore.folders.first(where: { $0.id == id }), folder.spaceID != spaceID,
              spaces.contains(where: { $0.id == folder.spaceID && $0.profileID == profileID }),
              tabStore.tabs.allSatisfy({ $0.profileID == profileID }) else { return false }
        let previousActive = activeTabID
        let oldOrder = tabStore.openTabs(in: folder.spaceID).map(\.id)
        guard let moved = tabStore.moveFolder(id, toSpace: spaceID) else { return false }
        recentlyClosed.removeAll {
            moved.tabIDs.contains($0.tab.id) || $0.tab.folderID.map { moved.folderIDs.contains($0) } == true
        }
        pruneSelections()
        if let previousActive, moved.tabIDs.contains(previousActive) {
            let index = oldOrder.firstIndex(of: previousActive) ?? 0
            let next = oldOrder.dropFirst(index + 1).first { !moved.tabIDs.contains($0) }
                ?? oldOrder.prefix(index).last { !moved.tabIDs.contains($0) }
            selectionBySpace[activeSpaceID] = next
            dismissCommandBar()
        }
        restoreSelection()
        if follow {
            _ = switchSpace(to: spaceID)
            if let previousActive, moved.tabIDs.contains(previousActive) { selectOpenTab(previousActive) }
        }
        return true
    }

    @discardableResult
    public func switchSpace(to id: UUID) -> Bool {
        guard spaces.contains(where: { $0.id == id && $0.profileID == profileID }) else { return false }
        activeSpaceID = id
        dismissCommandBar()
        restoreSelection()
        return true
    }

    private func pruneSelections() {
        selectionBySpace = selectionBySpace.filter { space, id in
            spaces.contains { $0.id == space } && tabStore.tabs.contains {
                $0.id == id && $0.profileID == profileID && $0.isOpen && $0.isVisible(in: space)
            }
        }
    }

    private func restoreSelection() {
        guard let id = selectionBySpace[activeSpaceID],
              let tab = tabStore.tab(id: id), tab.isOpen,
              canAccess(tab) else {
            selectionBySpace[activeSpaceID] = nil
            content = .empty
            return
        }
        content = .web(tabID: id)
    }

    private func canAccess(_ tab: BrowserTab) -> Bool {
        tab.profileID == profileID && tab.isVisible(in: activeSpaceID)
    }
}
