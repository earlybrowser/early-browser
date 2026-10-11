import Foundation
import Observation

/// One coordinator per browser window. UI actions all enter through this type.
@MainActor @Observable
public final class BrowserCoordinator {
    public private(set) var tabStore: TabStore
    public private(set) var activeSpaceID: UUID
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
        recentlyClosed: [ClosedTab] = []
    ) {
        self.activeSpaceID = activeSpaceID
        self.tabStore = tabStore
        self.selectionBySpace = selectionBySpace
        self.profileID = profileID
        self.recentlyClosed = Array(recentlyClosed.suffix(20))
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
              tab.spaceID == activeSpaceID else { return }
        selectionBySpace[activeSpaceID] = id
        content = .web(tabID: id)
        dismissCommandBar()
    }

    /// Sidebar selection can reopen a persistent pin. Never duplicate its record.
    @discardableResult
    public func openTab(_ id: UUID) -> Bool {
        guard let tab = tabStore.tab(id: id), tab.spaceID == activeSpaceID,
              tab.isOpen || tab.pinnedURL != nil else { return false }
        tabStore.reopen(id)
        recentlyClosed.removeAll { $0.tab.id == id }
        selectOpenTab(id)
        return true
    }

    @discardableResult
    public func setPinned(_ id: UUID, pinned: Bool) -> Bool {
        guard tabStore.tab(id: id)?.spaceID == activeSpaceID,
              tabStore.setPinned(id, pinned: pinned) else { return false }
        // Do not let a stale closure later restore the pre-unpin state.
        recentlyClosed.removeAll { $0.tab.id == id }
        return true
    }

    /// Reset is an explicit navigation, including when the pin was closed.
    @discardableResult
    public func resetPinnedTab(_ id: UUID) -> URL? {
        guard let tab = tabStore.tab(id: id), tab.spaceID == activeSpaceID,
              let url = tab.pinnedURL else { return nil }
        tabStore.update(id, url: url)
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
                       recentlyClosed: recentlyClosed)
    }

    @discardableResult
    public func navigate(to url: URL, target: NavigationRequest.Target) -> UUID? {
        let id: UUID
        switch target {
        case .currentTab(let existing):
            guard let tab = tabStore.tab(id: existing), tab.isOpen,
                  tab.spaceID == activeSpaceID else { return nil }
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
        let nextID = tabStore.close(id: id)
        recentlyClosed.removeAll { $0.tab.id == id }
        // History must use the reset pin too, including persisted reopen paths.
        recentlyClosed.append(ClosedTab(tab: tabStore.tab(id: id) ?? tab, position: index))
        recentlyClosed = Array(recentlyClosed.suffix(20))
        if selectionBySpace[tab.spaceID] == id { selectionBySpace[tab.spaceID] = nextID }
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
        activeSpaceID = closed.tab.spaceID
        selectOpenTab(closed.tab.id)
        return closed.tab.id
    }

    public func switchSpace(to id: UUID) {
        activeSpaceID = id
        dismissCommandBar()
        restoreSelection()
    }

    private func restoreSelection() {
        guard let id = selectionBySpace[activeSpaceID],
              let tab = tabStore.tab(id: id), tab.isOpen,
              tab.spaceID == activeSpaceID else {
            selectionBySpace[activeSpaceID] = nil
            content = .empty
            return
        }
        content = .web(tabID: id)
    }
}
