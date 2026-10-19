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
        }
    }

    /// Dispatch only completed actions. Ordinary metadata changes deliberately
    /// leave the page/editor's first responder alone; a command-bar action ends
    /// its presentation unless it opens another editor or fails validation.
    @discardableResult
    func perform(_ action: BrowserAction, source: BrowserActionSource = .interface) -> Bool {
        guard canPerform(action) else { return false }
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
        }
        if source == .commandBar && coordinator.commandBar != nil {
            dismissCommandBar(restoreFocus: restoreContentFocus && contentFocusRequest == previousFocusRequest)
        } else if coordinator.commandBar == nil {
            // Coordinators can dismiss while selecting/reopening a tab. Cancel
            // its asynchronous query too, not only the visible presentation.
            suggestions.cancel()
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
}
