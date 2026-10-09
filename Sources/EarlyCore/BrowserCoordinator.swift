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
    private var selectionBySpace: [UUID: UUID]

    public init(
        startup: StartupContext,
        activeSpaceID: UUID = UUID(),
        tabStore: TabStore = TabStore(),
        selectionBySpace: [UUID: UUID] = [:]
    ) {
        self.activeSpaceID = activeSpaceID
        self.tabStore = tabStore
        self.selectionBySpace = selectionBySpace
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

    /// Phase 0 exposes submission intent without pretending navigation exists.
    /// Phase 1 will consume this request through a validating navigation service.
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

    /// Returns the runtime identity the owner must release, if anything closed.
    @discardableResult
    public func closeActiveTab() -> UUID? {
        // With zero tabs, Command+W is a true no-op, including a visible bar.
        guard case .web(let id) = content else { return nil }
        let nextID = tabStore.close(id: id)
        selectionBySpace[activeSpaceID] = nextID
        content = nextID.map { .web(tabID: $0) } ?? .empty
        dismissCommandBar()
        return id
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
