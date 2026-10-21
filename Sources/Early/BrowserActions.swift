// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore

enum BrowserActionSource: Equatable {
    case interface
    case commandBar
}

@MainActor
extension BrowserWindowModel {
    /// UI controls and future command results use exactly the same availability
    /// rules. A stale/foreign result must not dismiss an editor or change focus.
    func canPerform(_ action: BrowserAction) -> Bool {
        if case .dismissCommandBar = action { return coordinator.commandBar != nil }
        guard !sidebarInteractionInProgress, !spaceSwipeIsSettling,
              !folderEditorIsPresented, renamingTabID == nil, spaceEditor == nil,
              spaceDeletionID == nil, activePage?.hasDialog != true else { return false }
        switch action {
        case .presentCommandBar, .toggleSidebar:
            return true
        case .dismissCommandBar:
            return coordinator.commandBar != nil
        case .submit(let suggestion):
            guard !commandBarIsComposing,
                  (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                  coordinator.navigationRequest() != nil else { return false }
            return suggestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        case .selectTab(let id):
            guard let tab = accessibleTab(id) else { return false }
            return tab.isOpen || tab.pinnedURL != nil
        case .selectTabNumber(let number):
            guard (1...9).contains(number) else { return false }
            let index = number == 9 ? openTabs.count - 1 : number - 1
            return openTabs.indices.contains(index) && accessibleTab(openTabs[index].id) != nil
        case .cycleTab(let direction):
            let tabs = openTabs
            guard [-1, 1].contains(direction), !tabs.isEmpty else { return false }
            let current = tabs.firstIndex { $0.id == coordinator.activeTabID } ?? 0
            return accessibleTab(tabs[(current + direction + tabs.count) % tabs.count].id) != nil
        case .closeTab(let id):
            return accessibleTab(id)?.isOpen == true
        case .closeActiveTab:
            return activeTab != nil
        case .reopenLastTab:
            guard let tab = coordinator.recentlyClosed.last?.tab else { return false }
            return tab.profileID == coordinator.profileID && ownsSpace(tab.spaceID)
        case .setPinned(let id, let pinned):
            guard let tab = accessibleTab(id), !tab.isFavorite,
                  (tab.pinnedURL != nil) != pinned else { return false }
            return !pinned || tab.isOpen
        case .setFavorite(let id, let favorite):
            guard let tab = accessibleTab(id), tab.isFavorite != favorite else { return false }
            return !favorite || tab.pinnedURL != nil || tab.isOpen
        case .setMuted(let id, let muted):
            guard accessibleTab(id)?.isOpen == true, let page = webViews.pages[id] else { return false }
            return page.isMuted != muted
        case .resetPinnedTab(let id):
            return accessibleTab(id)?.pinnedURL != nil
        case .requestRename(let id):
            return accessibleTab(id) != nil
        case .moveTabBy(let id, let direction):
            guard [-1, 1].contains(direction), let tab = accessibleTab(id) else { return false }
            let siblings = coordinator.tabStore.siblingIDs(of: tab)
            guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + direction) else { return false }
            let target = siblings[index + direction]
            return accessibleTab(target) != nil || coordinator.folders.contains { $0.id == target }
        case .moveTab(let id, let spaceID):
            guard let tab = accessibleTab(id) else { return false }
            return canManageSpaces && !tab.isFavorite && tab.spaceID != spaceID && ownsSpace(spaceID)
        case .moveFolder(let id, let spaceID):
            guard let folder = coordinator.folders.first(where: { $0.id == id }) else { return false }
            return canManageSpaces && folder.spaceID != spaceID && ownsSpace(spaceID)
        case .deleteFolder(let id):
            return coordinator.folders.contains { $0.id == id }
        case .switchSpace(let id):
            return canManageSpaces && id != coordinator.activeSpaceID && ownsSpace(id)
        case .cycleSpace(let delta):
            return canManageSpaces && SpaceNavigation.targetIndex(current: activeSpaceIndex,
                count: coordinator.spaces.count, delta: delta) != nil
        case .selectSpaceNumber(let number):
            return canManageSpaces && SpaceNavigation.shortcutIndex(number: number, count: coordinator.spaces.count) != nil
        case .newSpace:
            return canManageSpaces
        case .editSpace(let id), .duplicateSpace(let id):
            return canManageSpaces && ownsSpace(id)
        case .deleteSpace(let id):
            return canManageSpaces && coordinator.spaces.count > 1 && ownsSpace(id)
        case .openProfile(let id):
            return application?.profileOperationInProgress == false && application?.profiles.contains { $0.id == id } == true
        case .copyCurrentURL:
            return currentPageURL != nil
        case .back:
            return activePage?.canGoBack == true
        case .forward:
            return activePage?.canGoForward == true
        case .reload:
            return activePage != nil
        case .stop:
            return activePage?.isLoading == true
        case .openTabInNewWindow(let id):
            guard let tab = accessibleTab(id), onOpenWindow != nil else { return false }
            let url = tab.isOpen ? tab.currentURL : (tab.pinnedURL ?? tab.currentURL)
            return (tab.isOpen || tab.pinnedURL != nil) && (try? input.validate(url)) != nil
        case .duplicateTab(let id):
            guard let tab = accessibleTab(id) else { return false }
            let url = tab.isOpen ? tab.currentURL : (tab.pinnedURL ?? tab.currentURL)
            return (tab.isOpen || tab.pinnedURL != nil) && (try? input.validate(url)) != nil
        case .openSettings:
            return onOpenSettings != nil
        }
    }

    /// Dispatch only completed actions. Ordinary metadata changes deliberately
    /// leave the page/editor's first responder alone; a command-bar action ends
    /// its presentation unless it opens another editor or fails validation.
    @discardableResult
    func perform(_ action: BrowserAction, source: BrowserActionSource = .interface) -> Bool {
        guard canPerform(action) else { return false }
        cancelTabSwitcher(restoreFocus: false)
        let previousFocusRequest = contentFocusRequest
        var restoreContentFocus = true
        switch action {
        case .presentCommandBar(let intent):
            presentCommandBar(intent)
            return true
        case .dismissCommandBar(let restoreFocus):
            dismissCommandBar(restoreFocus: restoreFocus)
            return true
        case .submit(let suggestion):
            return submit(searchSuggestion: suggestion)
        case .selectTab(let id): selectTab(id)
        case .selectTabNumber(let number): selectTab(number: number)
        case .cycleTab(let direction): cycleTab(direction)
        case .closeTab(let id): closeTab(id)
        case .closeActiveTab: closeActiveTab()
        case .reopenLastTab: reopenLastTab()
        case .setPinned(let id, let pinned): setPinned(id, pinned: pinned)
        case .setFavorite(let id, let favorite): setFavorite(id, favorite: favorite)
        case .setMuted(let id, let muted):
            guard webViews.setMuted(muted, for: id) else { return false }
        case .resetPinnedTab(let id): resetPinnedTab(id)
        case .requestRename(let id):
            requestRename(id)
            restoreContentFocus = false
        case .moveTabBy(let id, let direction): moveTab(id, direction: direction)
        case .moveTab(let id, let spaceID):
            guard moveTab(id, toSpace: spaceID) else { return false }
        case .moveFolder(let id, let spaceID):
            guard moveFolder(id, toSpace: spaceID) else { return false }
        case .deleteFolder(let id): deleteFolder(id)
        case .switchSpace(let id):
            guard switchSpace(to: id) else { return false }
        case .cycleSpace(let delta): cycleSpace(delta)
        case .selectSpaceNumber(let number): selectSpace(number: number)
        case .newSpace:
            requestNewSpace()
            restoreContentFocus = false
        case .editSpace(let id):
            requestEditSpace(id)
            restoreContentFocus = false
        case .duplicateSpace(let id): duplicateAndSelectSpace(id)
        case .deleteSpace(let id):
            requestDeleteSpace(id)
            restoreContentFocus = false
        case .openProfile(let id):
            application?.openProfile(id)
            restoreContentFocus = false
        case .copyCurrentURL: copyCurrentURL()
        case .back: back()
        case .forward: forward()
        case .reload: reload()
        case .stop: stop()
        case .toggleSidebar: preferences.sidebarAutoHides.toggle()
        case .openTabInNewWindow(let id):
            openTabInNewWindow(id)
            restoreContentFocus = false
        case .duplicateTab(let id):
            guard duplicateTab(id) != nil else { return false }
        case .openSettings:
            onOpenSettings?()
            restoreContentFocus = false
        }
        if source == .commandBar && coordinator.commandBar != nil {
            dismissCommandBar(restoreFocus: restoreContentFocus && contentFocusRequest == previousFocusRequest)
        } else if coordinator.commandBar == nil {
            // Coordinators can dismiss while selecting/reopening a tab. Cancel
            // its asynchronous query too, not only the visible presentation.
            cancelCommandBarQueries()
            submissionMessage = nil
            commandBarIsComposing = false
        }
        return true
    }

    private func accessibleTab(_ id: UUID) -> BrowserTab? {
        guard let tab = coordinator.tabStore.tab(id: id), tab.profileID == coordinator.profileID,
              tab.isVisible(in: coordinator.activeSpaceID) else { return nil }
        return tab
    }

    private func ownsSpace(_ id: UUID) -> Bool {
        coordinator.spaces.contains { $0.id == id && $0.profileID == coordinator.profileID }
    }


    /// Snapshot searchable records and currently available actions on the main
    /// actor before handing the immutable array to `CommandSearch`.
    func commandSearchCandidates() -> [CommandSearchCandidate] {
        var candidates: [CommandSearchCandidate] = []
        var seenTabs = Set<UUID>()
        for tab in favorites + pinnedTabs + todayTabs where seenTabs.insert(tab.id).inserted {
            guard canPerform(.selectTab(tab.id)) else { continue }
            let kind: CommandSearchCandidate.Kind = tab.isFavorite ? .favorite : (tab.pinnedURL != nil ? .pinnedTab : .openTab)
            let displayURL = (tab.isOpen ? tab.currentURL : (tab.pinnedURL ?? tab.currentURL)).absoluteString
            var terms = [tab.title, tab.currentURL.absoluteString]
            if let custom = tab.customTitle { terms.append(custom) }
            if let pinned = tab.pinnedTitle { terms.append(pinned) }
            if let pinned = tab.pinnedURL { terms.append(pinned.absoluteString) }
            candidates.append(CommandSearchCandidate(
                id: "tab.\(tab.id.uuidString)", kind: kind, target: .tab(tab.id),
                title: tab.displayTitle, detail: displayURL, terms: terms,
                isOpen: tab.isOpen, lastUsed: tab.lastActivatedAt, useCount: tab.activationCount))
        }
        guard commandBarActionsEnabled else { return candidates }
        for space in coordinator.spaces where canPerform(.switchSpace(space.id)) {
            candidates.append(CommandSearchCandidate(
                id: "space.\(space.id.uuidString)", kind: .space, target: .space(space.id),
                title: space.name, terms: ["switch space \(space.name)", "space \(space.name)"]))
        }
        for profile in application?.profiles ?? [] where profile.id != coordinator.profileID && canPerform(.openProfile(profile.id)) {
            candidates.append(CommandSearchCandidate(
                id: "profile.\(profile.id.uuidString)", kind: .profile, target: .profile(profile.id),
                title: profile.name, terms: ["switch profile \(profile.name)", "profile \(profile.name)"]))
        }
        func addAction(_ id: String, _ title: String, _ action: BrowserAction, terms: [String]) {
            guard canPerform(action) else { return }
            candidates.append(CommandSearchCandidate(
                id: "action.\(id)", kind: .action, target: .action(action), title: title, terms: terms))
        }
        addAction("closeActiveTab", "Close Tab", .closeActiveTab, terms: ["close current tab"])
        addAction("reopenLastTab", "Reopen Closed Tab", .reopenLastTab, terms: ["restore closed tab", "undo close tab"])
        addAction("copyCurrentURL", "Copy Current URL", .copyCurrentURL, terms: ["copy link", "copy address"])
        addAction("reload", "Reload Page", .reload, terms: ["refresh page"])
        addAction("stop", "Stop Loading", .stop, terms: ["cancel loading"])
        addAction("back", "Back", .back, terms: ["go back", "previous page"])
        addAction("forward", "Forward", .forward, terms: ["go forward", "next page"])
        addAction("toggleSidebar", "Toggle Sidebar", .toggleSidebar, terms: ["show sidebar", "hide sidebar"])
        addAction("newSpace", "New Space", .newSpace, terms: ["create space", "add space"])
        addAction("openSettings", "Open Settings", .openSettings, terms: ["settings", "preferences"])
        if let tab = activeTab {
            let muted = webViews.pages[tab.id]?.isMuted == true
            addAction("mute.\(tab.id.uuidString)", muted ? "Unmute Tab" : "Mute Tab",
                      .setMuted(tab.id, !muted), terms: [muted ? "unmute audio" : "mute audio", "tab sound"])
            let pinned = tab.pinnedURL != nil
            addAction("pin.\(tab.id.uuidString)", pinned ? "Unpin Tab" : "Pin Tab",
                      .setPinned(tab.id, !pinned), terms: [pinned ? "unpin current tab" : "pin current tab"])
            addAction("favorite.\(tab.id.uuidString)", tab.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      .setFavorite(tab.id, !tab.isFavorite),
                      terms: [tab.isFavorite ? "unfavorite tab" : "favorite current tab"])
            addAction("resetPin.\(tab.id.uuidString)", "Reset Pinned Tab", .resetPinnedTab(tab.id),
                      terms: ["return to pinned url", "restore pinned address"])
            addAction("rename.\(tab.id.uuidString)", "Rename Tab", .requestRename(tab.id),
                      terms: ["rename current tab", "edit tab title"])
            addAction("duplicate.\(tab.id.uuidString)", "Duplicate Tab", .duplicateTab(tab.id),
                      terms: ["duplicate current tab", "clone tab", "copy tab"])
            addAction("newWindow.\(tab.id.uuidString)", "Open Tab in New Window", .openTabInNewWindow(tab.id),
                      terms: ["move tab to new window"])
            for space in coordinator.spaces where space.id != tab.spaceID {
                addAction("move.\(tab.id.uuidString).\(space.id.uuidString)", "Move Tab to \(space.name)",
                          .moveTab(tab.id, toSpace: space.id), terms: ["move current tab \(space.name)"])
            }
        }
        return candidates
    }

    func commandResultBadge(for candidate: CommandSearchCandidate) -> String {
        if case .tab(let id) = candidate.target, id == coordinator.focusedTabID {
            return "Current tab"
        }
        switch candidate.kind {
        case .favorite: return candidate.isOpen ? "Switch to Tab" : "Open Favorite"
        case .pinnedTab: return candidate.isOpen ? "Switch to Tab" : "Open Pin"
        case .openTab: return "Switch to Tab"
        case .space: return "Switch Space"
        case .profile: return "Switch Profile"
        case .action: return "Command"
        case .bookmark: return "Open Bookmark"
        case .history: return "Open History"
        }
    }

    /// Ranked tabs, pins, Favorites, and (when enabled) Spaces, profiles, and actions.
    var visibleCommandResults: [CommandSearchResult] {
        commandBarActionsEnabled ? commandSearch.results
            : commandSearch.results.filter { $0.candidate.kind.isTab || $0.candidate.kind == .bookmark || $0.candidate.kind == .history }
    }

    var selectedCommandResult: CommandSearchResult? {
        guard !commandSearch.isRefreshing, let id = commandSearch.selectedID else { return nil }
        return visibleCommandResults.first { $0.id == id }
    }

    var selectedCommandResultIndex: Int? {
        guard !commandSearch.isRefreshing, let id = commandSearch.selectedID else { return nil }
        return visibleCommandResults.firstIndex { $0.id == id }
    }

    func selectCommandResult(id: String?) {
        guard !commandSearch.isRefreshing, let id,
              let index = commandSearch.results.firstIndex(where: { $0.id == id }) else {
            commandSearch.select(index: nil)
            return
        }
        suggestions.select(index: nil)
        commandSearch.select(index: index)
    }

    func moveCommandBarSelection(_ delta: Int) -> Bool {
        guard !commandBarIsComposing else { return false }
        let local = commandSearch.isRefreshing ? [] : visibleCommandResults
        let remote = suggestions.isRefreshing ? [] : suggestions.results
        let total = local.count + remote.count
        guard total > 0 else { return false }
        let current: Int?
        if let index = selectedCommandResultIndex {
            current = index
        } else if let index = suggestions.selectedIndex {
            current = local.count + index
        } else {
            current = nil
        }
        let next = (current ?? (delta > 0 ? -1 : total)) + delta
        commandSearch.select(index: nil)
        suggestions.select(index: nil)
        guard (0..<total).contains(next) else { return true }
        if next < local.count {
            selectCommandResult(id: local[next].id)
        } else {
            suggestions.select(index: next - local.count)
        }
        return true
    }

    @discardableResult
    func performCommandBarSelection() -> Bool {
        if let result = selectedCommandResult {
            return perform(result, source: .commandBar)
        }
        return perform(.submit(searchSuggestion: suggestions.selectedSuggestion), source: .commandBar)
    }

    @discardableResult
    func perform(_ result: CommandSearchResult, source: BrowserActionSource = .commandBar) -> Bool {
        switch result.candidate.target {
        case .tab(let id):
            if id == coordinator.focusedTabID {
                guard canPerform(.selectTab(id)) else { return false }
                // The current result is a confirmation, not a new activation:
                // do not reveal folders, save, recover/reload, or reset the page.
                if coordinator.commandBar != nil {
                    return perform(.dismissCommandBar(restoreFocus: true), source: source)
                }
                return true
            }
            return perform(.selectTab(id), source: source)
        case .space(let id): return perform(.switchSpace(id), source: source)
        case .profile(let id): return perform(.openProfile(id), source: source)
        case .action(let action): return perform(action, source: source)
        case .page(let url, _):
            guard canPerform(.submit()) else { return false }
            let ok = submit(targetURL: url)
            if ok && source == .commandBar && coordinator.commandBar != nil {
                dismissCommandBar(restoreFocus: true)
            }
            return ok
        }
    }
}
