import AppKit
import EarlyCore
import EarlyWeb
import Observation
import WebKit

@MainActor @Observable
final class BrowserWindowModel {
    let coordinator: BrowserCoordinator
    let webViews: WebViewManager
    let input: NavigationInput
    let persistence: SessionAutosaver
    let isTesting: Bool
    var submissionMessage: String?
    var notice: String?
    var renamingTabID: UUID?
    var renameText = ""
    var contentFocusRequest = 0

    init(startup: StartupContext, session: BrowserSession, repository: SessionRepository,
         input: NavigationInput, isTesting: Bool, restorationError: String?) {
        self.input = input
        self.isTesting = isTesting
        coordinator = BrowserCoordinator(startup: startup, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs), selectionBySpace: session.selectionBySpace,
            profileID: session.profileID, recentlyClosed: session.recentlyClosed)
        persistence = SessionAutosaver(repository: repository, disabledReason: restorationError)
        webViews = WebViewManager(profileID: session.profileID, ephemeral: isTesting, input: input) { configuration in
            #if DEBUG
            if isTesting { configuration.setURLSchemeHandler(TestPages(), forURLScheme: "early-test") }
            #endif
        }
        webViews.onMetadata = { [weak self] id, url, title in
            guard let self, self.coordinator.updateMetadata(id, url: url, title: title) else { return }
            self.save()
        }
        webViews.onNewWindow = { [weak self] url, configuration in
            guard let self, let id = self.coordinator.navigate(to: url, target: .newTab(spaceID: self.coordinator.activeSpaceID)),
                  let tab = self.coordinator.tabStore.tab(id: id) else { return nil }
            let view = self.webViews.prepare(tab, configuration: configuration).view
            self.save()
            self.contentFocusRequest += 1
            // WebKit performs this load after the delegate returns the new view.
            return view
        }
        webViews.onClose = { [weak self] in self?.closeTab($0) }
        webViews.onNotice = { [weak self] in self?.notice = $0 }
        activateSelection()
        save()
    }

    var activePage: BrowserPage? { coordinator.activeTabID.flatMap { webViews.pages[$0] } }
    var activeTab: BrowserTab? { coordinator.activeTabID.flatMap { coordinator.tabStore.tab(id: $0) } }
    var openTabs: [BrowserTab] {
        coordinator.tabStore.openTabs(in: coordinator.activeSpaceID)
    }
    var pinnedTabs: [BrowserTab] { coordinator.tabStore.pinnedTabs(in: coordinator.activeSpaceID) }
    var favorites: [BrowserTab] { coordinator.tabStore.favorites }
    var todayTabs: [BrowserTab] { coordinator.tabStore.todayTabs(in: coordinator.activeSpaceID) }

    func presentCommandBar(_ intent: CommandBarIntent) {
        submissionMessage = nil
        coordinator.presentCommandBar(intent)
    }

    func dismissCommandBar() {
        coordinator.dismissCommandBar()
        contentFocusRequest += 1
    }

    func submit() {
        guard let request = coordinator.navigationRequest() else { return }
        do {
            let url = try input.resolve(request.query)
            guard let id = coordinator.navigate(to: url, target: request.target),
                  let tab = coordinator.tabStore.tab(id: id) else { return }
            submissionMessage = nil
            notice = nil
            webViews.load(url, in: tab)
            contentFocusRequest += 1
            save()
        } catch { submissionMessage = error.localizedDescription }
    }

    func selectTab(_ id: UUID) {
        guard coordinator.openTab(id) else { return }
        activateSelection()
        save()
    }

    func setPinned(_ id: UUID, pinned: Bool) {
        guard coordinator.setPinned(id, pinned: pinned) else { return }
        // Metadata-only: do not reload, select, or allocate a web view.
        save()
    }

    func setFavorite(_ id: UUID, favorite: Bool) {
        guard coordinator.setFavorite(id, favorite: favorite) else { return }
        save()
    }

    func requestRename(_ id: UUID) {
        guard let tab = coordinator.tabStore.tab(id: id) else { return }
        renameText = tab.displayTitle
        renamingTabID = id
    }

    func reorderTab(_ id: UUID, on target: UUID, after: Bool) -> Bool {
        guard coordinator.reorderTab(id, relativeTo: target, after: after) else { return false }
        save()
        return true
    }

    func moveTab(_ id: UUID, direction: Int) {
        guard let tab = coordinator.tabStore.tab(id: id) else { return }
        let peers = coordinator.tabStore.peers(of: tab)
        guard [-1, 1].contains(direction), let index = peers.firstIndex(where: { $0.id == id }),
              peers.indices.contains(index + direction) else { return }
        _ = reorderTab(id, on: peers[index + direction].id, after: direction > 0)
    }

    func finishRename(usePageTitle: Bool = false) {
        guard let id = renamingTabID else { return }
        if coordinator.renameTab(id, to: usePageTitle ? "" : renameText) { save() }
        renamingTabID = nil
    }

    func resetPinnedTab(_ id: UUID) {
        guard let url = coordinator.resetPinnedTab(id),
              let tab = coordinator.tabStore.tab(id: id) else { return }
        webViews.load(url, in: tab)
        contentFocusRequest += 1
        save()
    }

    func selectTab(number: Int) {
        let tabs = openTabs
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func cycleTab(_ direction: Int) {
        let tabs = openTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == coordinator.activeTabID } ?? 0
        selectTab(tabs[(current + direction + tabs.count) % tabs.count].id)
    }

    func closeActiveTab() {
        guard let id = coordinator.activeTabID else { return }
        closeTab(id)
    }

    func closeTab(_ id: UUID) {
        guard coordinator.closeTab(id) != nil else { return }
        webViews.discard(tabID: id)
        activateSelection()
        save()
    }

    func reopenLastTab() {
        guard coordinator.reopenLastTab() != nil else { return }
        activateSelection()
        save()
    }

    func activateSelection() {
        if let id = coordinator.activeTabID, let tab = coordinator.tabStore.tab(id: id) {
            webViews.activate(tab)
        }
        contentFocusRequest += 1
    }

    func reload() { if let id = coordinator.activeTabID { webViews.reload(id) } }
    func stop() { if let id = coordinator.activeTabID { webViews.stop(id) } }
    func back() { if let id = coordinator.activeTabID { webViews.back(id) } }
    func forward() { if let id = coordinator.activeTabID { webViews.forward(id) } }
    func save() { persistence.enqueue(coordinator.session) }
}

/// One writer, with only the latest pending snapshot retained during a burst.
/// Encoding and SQLite I/O take place on SessionRepository's actor.
@MainActor @Observable
final class SessionAutosaver {
    private let repository: SessionRepository
    private let disabledReason: String?
    private var pending: BrowserSession?
    private var writer: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var isSaving = false
    private(set) var error: String?

    init(repository: SessionRepository, disabledReason: String?) {
        self.repository = repository
        self.disabledReason = disabledReason
        error = disabledReason
    }

    func enqueue(_ snapshot: BrowserSession) {
        guard disabledReason == nil else { return }
        pending = snapshot
        guard writer == nil else { return }
        isSaving = true
        writer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            while let snapshot = self.pending {
                self.pending = nil
                self.revision += 1
                do {
                    try await self.repository.save(snapshot, revision: self.revision)
                    self.error = nil
                } catch { self.error = error.localizedDescription }
            }
            self.isSaving = false
            self.writer = nil
        }
    }

    func flush() async -> Bool {
        await writer?.value
        return error == nil
    }
}
