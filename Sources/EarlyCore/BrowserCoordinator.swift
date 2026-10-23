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
    public private(set) var splitGroups: [BrowserSplitGroup]
    public private(set) var focusedPaneByGroupID: [UUID: UUID]
    private var selectionBySpace: [UUID: UUID]
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        startup: StartupContext,
        activeSpaceID: UUID = UUID(),
        tabStore: TabStore = TabStore(),
        selectionBySpace: [UUID: UUID] = [:],
        profileID: UUID = UUID(),
        recentlyClosed: [ClosedTab] = [],
        spaces: [BrowserSpace]? = nil,
        splitGroups: [BrowserSplitGroup] = [],
        focusedPaneByGroupID: [UUID: UUID] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.activeSpaceID = activeSpaceID
        self.tabStore = tabStore
        self.selectionBySpace = selectionBySpace
        self.profileID = profileID
        self.recentlyClosed = Array(recentlyClosed.suffix(20))
        self.splitGroups = splitGroups
        self.focusedPaneByGroupID = focusedPaneByGroupID
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
        commandBar?.hasEditedQuery = true
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
        if commandBar.intent == .navigateCurrentTab, case .web(let id) = content,
           let tab = tabStore.tab(id: id), tab.pinnedURL == nil, !tab.isFavorite {
            target = .currentTab(id)
        } else {
            // Saved tabs are stable destinations. New command-bar searches or
            // addresses leave them intact and create a Today tab in this Space.
            // Website links/history still navigate their own live page normally.
            target = .newTab(spaceID: activeSpaceID)
        }
        return NavigationRequest(query: query, target: target)
    }

    public func selectOpenTab(_ id: UUID) {
        guard let tab = tabStore.tab(id: id), tab.isOpen,
              canAccess(tab) else { return }
        // Re-selecting the visible tab is not a new use. Restoring a Space's
        // remembered selection does not pass through here either.
        if content != .web(tabID: id) { tabStore.recordActivation(id, at: now()) }
        tabStore.revealFolderAncestors(of: id)
        selectionBySpace[activeSpaceID] = id
        if let group = splitGroups.first(where: { $0.spaceID == activeSpaceID && $0.panes.contains { $0.tabID == id } }),
           let pane = group.panes.first(where: { $0.tabID == id }) {
            focusedPaneByGroupID[group.id] = pane.id
        }
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
        pruneSelections()
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

    /// There is one command target per window, even with two visible panes.
    public var focusedTabID: UUID? { activeTabID }

    public var activeSplitGroup: BrowserSplitGroup? {
        guard let id = activeTabID else { return nil }
        return splitGroups.first { $0.spaceID == activeSpaceID && $0.panes.contains { $0.tabID == id } }
    }

    /// All group members are protected from future inactive-page eviction,
    /// even when only one pane currently owns keyboard focus.
    public var visibleTabIDs: Set<UUID> {
        if let group = activeSplitGroup { return Set(group.panes.map(\.tabID)) }
        return Set(activeTabID.map { [$0] } ?? [])
    }

    @discardableResult
    public func createSplit(between first: UUID, and second: UUID, leadingFraction: Double = 0.5) -> UUID? {
        let group = BrowserSplitGroup(spaceID: activeSpaceID,
            panes: [BrowserSplitPane(tabID: first), BrowserSplitPane(tabID: second)], leadingFraction: leadingFraction)
        let proposed = splitGroups + [group]
        guard BrowserSplitGroup.pruned(proposed, tabs: tabStore.tabs, spaces: spaces, profileID: profileID) == proposed else { return nil }
        splitGroups = proposed
        let selected = activeTabID == second ? second : first
        focusedPaneByGroupID[group.id] = group.panes.first { $0.tabID == selected }?.id
        selectOpenTab(selected)
        return group.id
    }

    @discardableResult
    public func focusPane(_ paneID: UUID) -> Bool {
        guard let group = splitGroups.first(where: { $0.spaceID == activeSpaceID && $0.panes.contains { $0.id == paneID } }),
              let pane = group.panes.first(where: { $0.id == paneID }),
              let tab = tabStore.tab(id: pane.tabID), tab.isOpen, canAccess(tab) else { return false }
        selectOpenTab(pane.tabID)
        return true
    }

    @discardableResult
    public func resizeSplit(_ id: UUID, leadingFraction: Double) -> Bool {
        guard leadingFraction.isFinite, BrowserSplitGroup.fractionRange.contains(leadingFraction),
              let index = splitGroups.firstIndex(where: { $0.id == id && $0.spaceID == activeSpaceID }),
              splitGroups[index].leadingFraction != leadingFraction else { return false }
        splitGroups[index].leadingFraction = leadingFraction
        return true
    }

    /// Swap the panes, not their identities, selection, widths or tab ordering.
    /// The focused pane follows its page to the other side without an MRU use.
    @discardableResult
    public func swapSplit(_ id: UUID) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == id && $0.spaceID == activeSpaceID }),
              splitGroups[index].panes.count == 2 else { return false }
        splitGroups[index].panes.swapAt(0, 1)
        return true
    }

    /// Removing layout is not closing either of its tabs or releasing a view.
    @discardableResult
    public func exitSplit(_ id: UUID) -> Bool {
        guard splitGroups.contains(where: { $0.id == id && $0.spaceID == activeSpaceID }) else { return false }
        splitGroups.removeAll { $0.id == id }
        focusedPaneByGroupID[id] = nil
        return true
    }

    /// Revalidate the entire proposal at commit. Replaced/detached members stay
    /// open; a tab belongs to only one group and keeps its durable identity.
    @discardableResult
    public func applySplit(_ placement: BrowserSplitPlacement) -> Bool {
        guard splitPlacement(for: placement.sourceTabID, on: placement.side) == placement else { return false }
        if placement.reusesExistingPane {
            guard let pane = activeSplitGroup?.panes.first(where: { $0.tabID == placement.sourceTabID }) else { return false }
            return focusPane(pane.id)
        }
        let previous = activeSplitGroup
        let panes = placement.tabIDs.enumerated().map { index, id in
            BrowserSplitPane(id: previous?.panes[index].id ?? UUID(), tabID: id)
        }
        let group = BrowserSplitGroup(id: previous?.id ?? UUID(), spaceID: activeSpaceID,
            panes: panes, leadingFraction: placement.leadingFraction)
        let removed = splitGroups.filter {
            $0.id == group.id || $0.panes.contains { $0.tabID == placement.sourceTabID }
        }.map(\.id)
        splitGroups.removeAll { removed.contains($0.id) }
        for id in removed { focusedPaneByGroupID[id] = nil }
        splitGroups.append(group)
        focusedPaneByGroupID[group.id] = panes[placement.side.index].id
        selectOpenTab(placement.sourceTabID)
        return true
    }

    /// Removing a pane exits its two-pane layout, not the underlying tab.
    @discardableResult
    public func removeSplitPane(_ id: UUID) -> Bool {
        guard let group = activeSplitGroup, let survivor = group.panes.first(where: { $0.id != id }),
              group.panes.contains(where: { $0.id == id }), exitSplit(group.id) else { return false }
        selectOpenTab(survivor.tabID)
        return true
    }

    public var session: BrowserSession {
        BrowserSession(profileID: profileID, activeSpaceID: activeSpaceID,
                       tabs: tabStore.tabs, selectionBySpace: selectionBySpace,
                       recentlyClosed: recentlyClosed, folders: tabStore.folders, spaces: spaces,
                       splitGroups: splitGroups, focusedPaneByGroupID: focusedPaneByGroupID)
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
        splitGroups = session.splitGroups
        focusedPaneByGroupID = session.focusedPaneByGroupID
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
                tab.mergeUsage(from: local)
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
        pruneSelections()
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
        pruneSelections()
        return true
    }

    @discardableResult
    public func createFolder(name: String, parentID: UUID? = nil) -> UUID? {
        tabStore.createFolder(name: name, parentID: parentID, spaceID: activeSpaceID)
    }

    /// A live folder at the end of this Space's pins.
    @discardableResult
    public func createLiveFolder(name: String, source: LiveFolder.Source) -> UUID? {
        tabStore.createLiveFolder(name: name, source: source, spaceID: activeSpaceID)
    }

    /// Brings every live folder filled from `source` up to date. Keeping
    /// removals remembered is for clearing a list that couldn't be read.
    @discardableResult
    public func syncLiveFolders(_ source: LiveFolder.Source, items: [LiveFolderItem], forgetsRemoved: Bool = true) -> Bool {
        var changed = false
        for folder in tabStore.folders where folder.live?.source == source {
            changed = tabStore.syncLiveFolder(folder.id, items: items, profileID: profileID, forgetsRemoved: forgetsRemoved) || changed
        }
        guard changed else { return false }
        let remaining = Set(tabStore.tabs.map(\.id))
        recentlyClosed.removeAll { $0.tab.liveItemID != nil && !remaining.contains($0.tab.id) }
        pruneSelections()
        return true
    }

    /// Removes a live folder's pin by hand, closing it first if it's open.
    @discardableResult
    public func dismissLiveItem(_ id: UUID) -> Bool {
        guard let tab = tabStore.tab(id: id), canAccess(tab), tab.liveItemID != nil else { return false }
        if tab.isOpen { closeTab(id) }
        guard tabStore.dismissLiveItem(id) else { return false }
        recentlyClosed.removeAll { $0.tab.id == id }
        pruneSelections()
        return true
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
        let previousSplit = activeSplitGroup
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
            let next = previousSplit?.panes.first { !removed.tabIDs.contains($0.tabID) }?.tabID
                ?? previousOrder.dropFirst(index + 1).first { !removed.tabIDs.contains($0) }
                ?? previousOrder.prefix(index).last { !removed.tabIDs.contains($0) }
            selectionBySpace[activeSpaceID] = next
            content = next.map { .web(tabID: $0) } ?? .empty
            dismissCommandBar()
        }
        pruneSelections()
        restoreSelection()
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
        pruneSelections()
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
                                 title: url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString), currentURL: url)
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
        let closeSpace = tab.isFavorite ? activeSpaceID : tab.spaceID
        let sibling = splitGroups.first { $0.spaceID == closeSpace && $0.panes.contains { $0.tabID == id } }?.panes.first { $0.tabID != id }?.tabID
        let fallback = tabStore.close(id: id, in: closeSpace)
        let nextID = sibling ?? fallback
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
        pruneSelections()
        restoreSelection()
        return id
    }

    /// Today tabs in the active Space other than `id`, top to bottom.
    public func todayTabIDs(otherThan id: UUID) -> [UUID] {
        guard isTodayTab(id) else { return [] }
        return tabStore.todayTabs(in: activeSpaceID).map(\.id).filter { $0 != id }
    }

    /// Today tabs below `id` in the active Space, top to bottom.
    public func todayTabIDs(below id: UUID) -> [UUID] {
        let today = tabStore.todayTabs(in: activeSpaceID).map(\.id)
        guard let index = today.firstIndex(of: id) else { return [] }
        return Array(today[(index + 1)...])
    }

    public var todayTabIDs: [UUID] { tabStore.todayTabs(in: activeSpaceID).map(\.id) }

    private func isTodayTab(_ id: UUID) -> Bool {
        tabStore.todayTabs(in: activeSpaceID).contains { $0.id == id }
    }

    /// Closes Today tabs only; pins, Favorites and folders are never touched.
    /// Each joins reopen history, bottom first, so Reopen Closed Tab brings
    /// them back from the top. `keeping` stays selected when it was kept.
    @discardableResult
    public func closeTodayTabs(_ ids: [UUID], keeping kept: UUID? = nil) -> [UUID] {
        let today = Set(tabStore.todayTabs(in: activeSpaceID).map(\.id))
        var closed: [UUID] = []
        for id in ids.reversed() where today.contains(id) && id != kept {
            if closeTab(id) != nil { closed.append(id) }
        }
        if let kept, !closed.isEmpty, tabStore.tab(id: kept)?.isOpen == true { selectOpenTab(kept) }
        return closed
    }

    @discardableResult
    public func reopenLastTab() -> UUID? {
        guard let id = recentlyClosed.last?.tab.id else { return nil }
        return reopenClosedTab(id)
    }

    /// Reopens one recently closed tab, not necessarily the last one closed.
    @discardableResult
    public func reopenClosedTab(_ id: UUID) -> UUID? {
        guard let index = recentlyClosed.lastIndex(where: { $0.tab.id == id }) else { return nil }
        var closed = recentlyClosed.remove(at: index)
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
        var snapshot = session
        snapshot.pruneSplitMetadata()
        splitGroups = snapshot.splitGroups
        focusedPaneByGroupID = snapshot.focusedPaneByGroupID
        selectionBySpace = snapshot.selectionBySpace
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
