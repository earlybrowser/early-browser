// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import Observation
import SwiftUI
import WebKit

@MainActor @Observable
final class BrowserWindowModel {
    enum SpaceEditor: Identifiable {
        case new, edit(UUID, selectOnSave: Bool = false)
        var id: String {
            switch self { case .new: "new"; case .edit(let id, _): id.uuidString }
        }
    }
    struct Toast: Identifiable {
        enum Kind { case copiedURL, newTab }
        let id = UUID()
        let kind: Kind
        var message: String {
            switch kind { case .copiedURL: "Copied Current URL"; case .newTab: "New Tab Created" }
        }
        var accessibilityIdentifier: String {
            switch kind { case .copiedURL: "browser.copiedURL"; case .newTab: "browser.newTabCreated" }
        }
    }
    struct SidebarReveal: Equatable {
        let id = UUID()
        let spaceID: UUID
        let itemID: String
    }
    let coordinator: BrowserCoordinator
    let webViews: WebViewManager
    let input: NavigationInput
    let persistence: SessionAutosaver
    let preferences: BrowserPreferences
    weak var application: EarlyAppDelegate?
    let isTesting: Bool
    var submissionMessage: String?
    var commandBarIsComposing = false
    var notice: String?
    var toast: Toast?
    var sidebarIsHidden = false
    var sidebarReveal: SidebarReveal?
    var spaceEditor: SpaceEditor?
    var spaceDeletionID: UUID?
    var spaceSwipeCreationProgress = 0.0
    var spaceSwipeProgress = 0.0
    var spaceSwipeIsSettling = false
    @ObservationIgnored private var spaceSwipeSettleTask: Task<Void, Never>?
    @ObservationIgnored private var spaceSwipeRevision = UUID()
    var sidebarInteractionInProgress = false {
        didSet { updateRuntimeInteraction() }
    }
    struct SplitResize: Equatable {
        let groupID: UUID
        var fraction: Double
    }
    private(set) var splitPreview: BrowserSplitPlacement?
    /// Entering content shows both targets; a proposal exists only INSIDE a card.
    private(set) var splitDropSourceID: UUID?
    private(set) var splitResize: SplitResize?
    @ObservationIgnored var onSplitPreviewFeedback: (() -> Void)?
    var folderEditorIsPresented = false
    var renamingTabID: UUID?
    var renameText = ""
    var contentFocusRequest = 0
    private(set) var tabSwitcher: TabSwitcher?
    private(set) var tabSwitcherCommitsOnControlRelease = false
    @ObservationIgnored private var tabSwitcherSpaceID: UUID?
    let suggestions: SearchSuggestions
    let commandSearch: CommandSearch
    var onSave: ((BrowserWindowModel) -> Void)?
    var onOpenWindow: ((URL, String?) -> Void)?
    var onOpenSettings: (() -> Void)?
    var sidebarWidth: Double {
        get { preferences.sidebarWidth }
        set { preferences.sidebarWidth = newValue }
    }

    func finishSidebarResize() {
        sidebarWidth = SidebarWidth.clamped(sidebarWidth)
    }
    var onlineSuggestionsEnabled: Bool {
        get { preferences.onlineSuggestions }
        set { preferences.onlineSuggestions = newValue; refreshSuggestions() }
    }
    var commandBarActionsEnabled: Bool {
        get { preferences.commandBarActions }
        set { preferences.commandBarActions = newValue; refreshSuggestions() }
    }

    init(startup: StartupContext, session: BrowserSession, repository: SessionRepository,
         input: NavigationInput, isTesting: Bool, restorationError: String?, defaults: UserDefaults = .standard,
         sharedPersistence: SessionAutosaver? = nil, websiteDataStore: WKWebsiteDataStore? = nil,
         preferences: BrowserPreferences? = nil, searchProviders: [any CommandSearchProvider] = [],
         configureWebView: ((WKWebViewConfiguration) -> Void)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.input = input
        self.isTesting = isTesting
        self.preferences = preferences ?? BrowserPreferences(defaults: defaults)
        let service = GoogleSearchSuggestions()
        suggestions = SearchSuggestions { query in
            #if DEBUG
            // Isolated UI tests never send typed text to an external provider.
            if isTesting {
                try await Task.sleep(for: .milliseconds(50))
                return ["\(query) guide", "\(query) examples", "\(query) tips"]
            }
            #endif
            return try await service.fetch(query)
        }
        commandSearch = CommandSearch(providers: searchProviders, now: now)
        coordinator = BrowserCoordinator(startup: startup, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), selectionBySpace: session.selectionBySpace,
            profileID: session.profileID, recentlyClosed: session.recentlyClosed, spaces: session.spaces,
            splitGroups: session.splitGroups, focusedPaneByGroupID: session.focusedPaneByGroupID, now: now)
        persistence = sharedPersistence ?? SessionAutosaver(repository: repository, disabledReason: restorationError)
        // Tests drive pressure explicitly; host resource usage must not change
        // which fixture pages survive while assertions are running.
        webViews = WebViewManager(profileID: session.profileID, ephemeral: isTesting, input: input,
                                 websiteDataStore: websiteDataStore,
                                 observesMemoryPressure: !isTesting) { configuration in
            if let configureWebView {
                configureWebView(configuration)
                return
            }
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
            self.showNewTabToastIfNeeded()
            self.save()
            self.contentFocusRequest += 1
            // WebKit performs this load after the delegate returns the new view.
            return view
        }
        webViews.onOpenBackgroundLink = { [weak self] url in
            guard let self else { return }
            let id = self.coordinator.openBackgroundTab(to: url)
            guard let tab = self.coordinator.tabStore.tab(id: id) else { return }
            self.webViews.load(url, in: tab)
            self.showNewTabToastIfNeeded()
            self.save()
            // Context-menu and Command-click actions load only the background view;
            // selection and the visible page's first responder stay unchanged.
        }
        webViews.onClose = { [weak self] in self?.closeTab($0) }
        webViews.onOpenWindowLink = { [weak self] url in self?.onOpenWindow?(url, nil) }
        webViews.onNotice = { [weak self] in self?.notice = $0 }
        activateSelection()
        if coordinator.activeTabID == nil { coordinator.presentCommandBar(.newTab) }
        // The app installs the shared writer before publishing the first snapshot.
    }

    var activePage: BrowserPage? { coordinator.focusedTabID.flatMap { webViews.pages[$0] } }
    var hasVisibleDialog: Bool { coordinator.visibleTabIDs.contains { webViews.pages[$0]?.hasDialog == true } }
    var activeTab: BrowserTab? { coordinator.focusedTabID.flatMap { coordinator.tabStore.tab(id: $0) } }
    var openTabs: [BrowserTab] {
        coordinator.tabStore.openTabs(in: coordinator.activeSpaceID)
    }
    var pinnedTabs: [BrowserTab] { coordinator.tabStore.pinnedTabs(in: coordinator.activeSpaceID) }
    var favorites: [BrowserTab] { coordinator.tabStore.favorites }
    var todayTabs: [BrowserTab] { coordinator.tabStore.todayTabs(in: coordinator.activeSpaceID) }

    func presentCommandBar(_ intent: CommandBarIntent) {
        cancelSplitPreview()
        finishSplitResize(commit: false)
        cancelTabSwitcher(restoreFocus: false)
        sidebarReveal = nil
        cancelSpaceSwipePresentation()
        cancelCommandBarQueries()
        submissionMessage = nil
        commandBarIsComposing = false
        coordinator.presentCommandBar(intent)
    }

    var currentPageURL: URL? { activePage?.view.url ?? activeTab?.currentURL }

    func copyCurrentURL() {
        guard let url = currentPageURL else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else { return }
        showToast(.copiedURL)
    }

    private func showNewTabToastIfNeeded() {
        guard sidebarIsHidden else { return }
        showToast(.newTab)
    }

    private func showToast(_ kind: Toast.Kind) {
        // A new identity restarts the confirmation lifetime on repeated actions.
        let confirmation = Toast(kind: kind)
        toast = confirmation
        if let window = NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                userInfo: [.announcement: confirmation.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func dismissCommandBar(restoreFocus: Bool = true) {
        cancelCommandBarQueries()
        commandBarIsComposing = false
        coordinator.dismissCommandBar()
        if restoreFocus { contentFocusRequest += 1 }
    }

    func cancelCommandBarQueries() {
        commandSearch.cancel()
        suggestions.cancel()
    }

    func refreshSuggestions() {
        guard let bar = coordinator.commandBar, !commandBarIsComposing,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else {
            cancelCommandBarQueries()
            return
        }
        if bar.intent == .navigateCurrentTab, !bar.hasEditedQuery {
            // An unedited Cmd-L prefill represents the active address, not a
            // search query that should expand local results beneath the caret.
            cancelCommandBarQueries()
            return
        }
        commandSearch.update(query: bar.query, candidates: commandSearchCandidates())
        suggestions.update(query: bar.query, enabled: onlineSuggestionsEnabled)
    }

    func updateQuery(_ query: String, isComposing: Bool = false) {
        commandBarIsComposing = isComposing
        coordinator.updateQuery(query)
        submissionMessage = nil
        refreshSuggestions()
    }

    @discardableResult
    func submit(searchSuggestion: String? = nil, targetURL: URL? = nil) -> Bool {
        guard !commandBarIsComposing,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
              let request = coordinator.navigationRequest() else { return false }
        if coordinator.commandBar?.intent == .navigateCurrentTab,
           coordinator.commandBar?.hasEditedQuery == false,
           searchSuggestion == nil, targetURL == nil, let tab = activeTab,
           tab.pinnedURL != nil || tab.isFavorite {
            // Return on a saved tab's untouched address is not a new search and
            // must not create a duplicate or reload the original page.
            dismissCommandBar(restoreFocus: true)
            return true
        }
        cancelCommandBarQueries()
        do {
            let url: URL
            if let targetURL {
                url = try input.validate(targetURL)
            } else if let searchSuggestion {
                url = try input.searchURL(for: searchSuggestion)
            } else {
                url = try input.resolve(request.query)
            }
            guard let id = coordinator.navigate(to: url, target: request.target),
                  let tab = coordinator.tabStore.tab(id: id) else { return false }
            submissionMessage = nil
            notice = nil
            webViews.load(url, in: tab)
            contentFocusRequest += 1
            save()
            return true
        } catch {
            submissionMessage = error.localizedDescription
            return false
        }
    }

    func selectTab(_ id: UUID) {
        let wasHiddenInFolder: Bool = {
            var parent = coordinator.tabStore.tab(id: id)?.folderID
            var seen = Set<UUID>()
            while let folderID = parent, seen.insert(folderID).inserted,
                  let folder = coordinator.folders.first(where: { $0.id == folderID }) {
                if !folder.isExpanded { return true }
                parent = folder.parentID
            }
            return false
        }()
        sidebarReveal = nil
        cancelSpaceSwipePresentation()
        guard coordinator.openTab(id) else { return }
        if wasHiddenInFolder {
            sidebarReveal = SidebarReveal(spaceID: coordinator.activeSpaceID, itemID: "tab-\(id)")
        }
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

    func placeTab(_ id: UUID, in section: TabStore.Section, folderID: UUID? = nil, before: UUID? = nil) -> Bool {
        guard coordinator.placeTab(id, in: section, folderID: folderID, before: before) else { return false }
        save()
        return true
    }

    func moveTab(_ id: UUID, direction: Int) {
        guard let tab = coordinator.tabStore.tab(id: id) else { return }
        let peers = coordinator.tabStore.siblingIDs(of: tab)
        guard [-1, 1].contains(direction), let index = peers.firstIndex(of: id),
              peers.indices.contains(index + direction) else { return }
        _ = reorderTab(id, on: peers[index + direction], after: direction > 0)
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

    var canPresentTabSwitcher: Bool {
        coordinator.commandBar == nil && !openTabs.isEmpty && canPerform(.cycleTab(1))
    }

    /// Preview is metadata/cache-only. Freeze MRU order until commit or cancel;
    /// never activate, snapshot, save, or allocate a page while stepping.
    @discardableResult
    func advanceTabSwitcher(_ delta: Int, commitsOnControlRelease: Bool = false) -> Bool {
        guard [-1, 1].contains(delta), canPresentTabSwitcher else {
            cancelTabSwitcher(restoreFocus: false)
            return false
        }
        validateTabSwitcher()
        if var selection = tabSwitcher {
            selection.step(delta)
            tabSwitcher = selection
        } else {
            tabSwitcher = TabSwitcher(openTabs: openTabs, activeTabID: coordinator.activeTabID, initialDelta: delta)
            tabSwitcherSpaceID = coordinator.activeSpaceID
        }
        tabSwitcherCommitsOnControlRelease = commitsOnControlRelease
        return tabSwitcher != nil
    }

    @discardableResult
    func selectTabSwitcherCandidate(_ id: UUID) -> Bool {
        validateTabSwitcher()
        guard var selection = tabSwitcher, selection.select(id) else { return false }
        tabSwitcher = selection
        return true
    }

    @discardableResult
    func commitTabSwitcher(selecting id: UUID? = nil) -> Bool {
        validateTabSwitcher()
        guard canPresentTabSwitcher, var selection = tabSwitcher else {
            cancelTabSwitcher(restoreFocus: false)
            return false
        }
        if let id, !selection.select(id) { return false }
        let action = selection.commitAction
        cancelTabSwitcher(restoreFocus: false)
        if let action { return perform(action) }
        contentFocusRequest += 1
        return true
    }

    func cancelTabSwitcher(restoreFocus: Bool = true) {
        let wasPresented = tabSwitcher != nil
        tabSwitcher = nil
        tabSwitcherSpaceID = nil
        tabSwitcherCommitsOnControlRelease = false
        if wasPresented && restoreFocus && coordinator.commandBar == nil { contentFocusRequest += 1 }
    }

    /// Page metadata can change asynchronously, but membership, selection, Space
    /// or modal changes invalidate the frozen selection instead of committing a
    /// stale target. A later physical Control release then has no effect.
    func validateTabSwitcher() {
        guard let selection = tabSwitcher else { return }
        if !canPresentTabSwitcher || tabSwitcherSpaceID != coordinator.activeSpaceID
            || selection.initialID != coordinator.activeTabID
            || Set(selection.tabIDs) != Set(openTabs.map(\.id)) {
            cancelTabSwitcher(restoreFocus: false)
        }
    }

    func closeActiveTab() {
        guard let id = coordinator.activeTabID else { return }
        closeTab(id)
    }

    func closeTab(_ id: UUID) {
        let previousActive = coordinator.activeTabID
        let previousVisible = coordinator.visibleTabIDs
        guard coordinator.closeTab(id) != nil else { return }
        webViews.discard(tabID: id)
        if previousActive != coordinator.activeTabID || previousVisible != coordinator.visibleTabIDs { activateSelection() }
        save()
    }

    func deleteFolder(_ id: UUID) {
        let previousActive = coordinator.activeTabID
        guard let removed = coordinator.deleteFolder(id) else { return }
        for tabID in removed { webViews.discard(tabID: tabID) }
        if let renamingTabID, removed.contains(renamingTabID) { self.renamingTabID = nil }
        if previousActive != coordinator.activeTabID { activateSelection() }
        save()
    }

    func reopenLastTab() {
        guard coordinator.reopenLastTab() != nil else { return }
        activateSelection()
        save()
    }

    @discardableResult
    func createSpace(name: String, color: BrowserSpace.Color = .blue, icon: SpaceIcon? = nil) -> UUID? {
        guard let id = coordinator.createSpace(name: name, color: color, icon: icon) else { return nil }
        save()
        return id
    }

    @discardableResult
    func editSpace(_ id: UUID, name: String, color: BrowserSpace.Color, icon: SpaceIcon?, selectOnSave: Bool = false) -> Bool {
        guard coordinator.editSpace(id, name: name, color: color, icon: icon) else { return false }
        if !selectOnSave || !switchSpace(to: id) { save() }
        return true
    }

    @discardableResult
    func duplicateSpace(_ id: UUID, name: String) -> UUID? {
        guard let copy = coordinator.duplicateSpace(id, name: name) else { return nil }
        save()
        return copy
    }

    @discardableResult
    func switchSpace(to id: UUID) -> Bool {
        guard id != coordinator.activeSpaceID, !sidebarInteractionInProgress else { return false }
        sidebarReveal = nil
        cancelSpaceSwipePresentation()
        guard coordinator.switchSpace(to: id) else { return false }
        cancelCommandBarQueries()
        submissionMessage = nil
        activateSelection()
        save()
        BrowserHaptics.alignment(enabled: preferences.haptics)
        return true
    }

    var canManageSpaces: Bool {
        !spaceSwipeIsSettling && !sidebarInteractionInProgress && splitResize == nil && !folderEditorIsPresented && !hasVisibleDialog
            && renamingTabID == nil && spaceEditor == nil && spaceDeletionID == nil
    }

    var activeSpaceIndex: Int { coordinator.spaces.firstIndex { $0.id == coordinator.activeSpaceID } ?? 0 }

    @discardableResult
    func reorderSpace(_ id: UUID, before beforeID: UUID?) -> Bool {
        guard canManageSpaces, coordinator.reorderSpace(id, before: beforeID) else { return false }
        cancelSpaceSwipePresentation()
        save()
        return true
    }

    /// VoiceOver/keyboard alternative to dragging an icon.
    @discardableResult
    func shiftSpace(_ id: UUID, by delta: Int) -> Bool {
        let spaces = coordinator.spaces
        guard canManageSpaces, let index = spaces.firstIndex(where: { $0.id == id }),
              SpaceNavigation.targetIndex(current: index, count: spaces.count, delta: delta) != nil else { return false }
        let beforeIndex = delta < 0 ? index - 1 : index + 2
        let before = beforeIndex < spaces.count ? spaces[beforeIndex].id : nil
        guard reorderSpace(id, before: before) else { return false }
        BrowserHaptics.alignment(enabled: preferences.haptics)
        return true
    }

    func updateSpaceSwipe(translation: Double) {
        guard canManageSpaces else { return }
        let progress = SpaceNavigation.sidebarTravel(translation: translation, width: sidebarWidth,
            canGoPrevious: activeSpaceIndex > 0, canGoNext: activeSpaceIndex + 1 < coordinator.spaces.count)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            spaceSwipeProgress = progress
        }
    }

    func cancelSpaceSwipePresentation() {
        spaceSwipeSettleTask?.cancel()
        spaceSwipeSettleTask = nil
        spaceSwipeRevision = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            spaceSwipeProgress = 0
            spaceSwipeCreationProgress = 0
            spaceSwipeIsSettling = false
        }
    }

    /// Settle the native sidebar page before committing selection. No page is
    /// activated and no session is saved while the fingers are still moving.
    func finishSpaceSwipe(_ action: SpaceSwipe.Action?) {
        guard !spaceSwipeIsSettling else { return }
        let action = canManageSpaces ? action : nil
        let source = coordinator.activeSpaceID
        let catalog = coordinator.spaces.map(\.id)
        let delta = action == .next ? 1 : -1
        let target = (action == .next || action == .previous)
            ? SpaceNavigation.targetIndex(current: activeSpaceIndex, count: catalog.count, delta: delta).map { catalog[$0] }
            : nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (spaceSwipeProgress == 0 && target == nil) {
            cancelSpaceSwipePresentation()
            if let target { _ = switchSpace(to: target) }
            else if action == .create { requestNewSpace() }
            return
        }
        let revision = UUID()
        spaceSwipeRevision = revision
        spaceSwipeIsSettling = true
        withAnimation(.easeOut(duration: target == nil ? 0.18 : 0.15)) {
            spaceSwipeProgress = target == nil ? 0 : (delta > 0 ? -1 : 1)
            spaceSwipeCreationProgress = 0
        }
        spaceSwipeSettleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(target == nil ? 180 : 150)) } catch { return }
            guard let self, self.spaceSwipeRevision == revision else { return }
            let contextMatches = self.coordinator.activeSpaceID == source && self.coordinator.spaces.map(\.id) == catalog
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.spaceSwipeIsSettling = false
                self.spaceSwipeSettleTask = nil
                self.spaceSwipeProgress = 0
                guard contextMatches, self.canManageSpaces else { return }
                if let target { _ = self.switchSpace(to: target) }
                else if action == .create { self.requestNewSpace() }
            }
        }
    }

    func cycleSpace(_ delta: Int) {
        guard canManageSpaces,
              let index = SpaceNavigation.targetIndex(current: activeSpaceIndex, count: coordinator.spaces.count, delta: delta) else { return }
        _ = switchSpace(to: coordinator.spaces[index].id)
    }

    func selectSpace(number: Int) {
        guard canManageSpaces,
              let index = SpaceNavigation.shortcutIndex(number: number, count: coordinator.spaces.count) else { return }
        _ = switchSpace(to: coordinator.spaces[index].id)
    }

    func requestNewSpace() {
        guard canManageSpaces else { return }
        cancelSpaceSwipePresentation()
        dismissCommandBar(restoreFocus: false)
        spaceEditor = .new
    }

    func requestEditSpace(_ id: UUID, selectOnSave: Bool = false) {
        guard canManageSpaces, coordinator.spaces.contains(where: { $0.id == id }) else { return }
        cancelSpaceSwipePresentation()
        dismissCommandBar(restoreFocus: false)
        spaceEditor = .edit(id, selectOnSave: selectOnSave)
    }

    func requestDeleteSpace(_ id: UUID) {
        guard canManageSpaces, coordinator.spaces.count > 1,
              coordinator.spaces.contains(where: { $0.id == id }) else { return }
        cancelSpaceSwipePresentation()
        dismissCommandBar(restoreFocus: false)
        spaceDeletionID = id
    }

    func duplicateAndSelectSpace(_ id: UUID) {
        guard canManageSpaces, let source = coordinator.spaces.first(where: { $0.id == id }),
              let copy = duplicateSpace(id, name: String(source.name.prefix(59)) + " Copy") else { return }
        _ = switchSpace(to: copy)
    }

    @discardableResult
    func deleteSpace(_ id: UUID) -> Bool {
        let previous = coordinator.activeTabID
        let previousSpace = coordinator.activeSpaceID
        guard let removed = coordinator.deleteSpace(id) else { return false }
        for tabID in removed { webViews.discard(tabID: tabID) }
        if let renamingTabID, removed.contains(renamingTabID) { self.renamingTabID = nil }
        if coordinator.commandBar == nil { cancelCommandBarQueries() }
        if previous != coordinator.activeTabID || previousSpace != coordinator.activeSpaceID { activateSelection() }
        save()
        return true
    }

    @discardableResult
    func moveTab(_ id: UUID, toSpace spaceID: UUID) -> Bool {
        cancelSpaceSwipePresentation()
        let previous = coordinator.activeTabID
        let previousSpace = coordinator.activeSpaceID
        guard coordinator.moveTab(id, toSpace: spaceID, follow: true) else { return false }
        finishSpaceMove(from: previousSpace, previousTab: previous, revealing: "tab-\(id)")
        return true
    }

    @discardableResult
    func moveFolder(_ id: UUID, toSpace spaceID: UUID) -> Bool {
        cancelSpaceSwipePresentation()
        let previous = coordinator.activeTabID
        let previousSpace = coordinator.activeSpaceID
        guard coordinator.moveFolder(id, toSpace: spaceID, follow: true) else { return false }
        finishSpaceMove(from: previousSpace, previousTab: previous, revealing: "folder-\(id)")
        return true
    }

    private func finishSpaceMove(from previousSpace: UUID, previousTab: UUID?, revealing itemID: String) {
        cancelCommandBarQueries()
        submissionMessage = nil
        if previousTab != coordinator.activeTabID || previousSpace != coordinator.activeSpaceID { activateSelection() }
        sidebarReveal = SidebarReveal(spaceID: coordinator.activeSpaceID, itemID: itemID)
        // Reuse moved live views; following never opens a closed pin or loads
        // every page in a folder. Only the final destination state is saved.
        save()
        if previousSpace != coordinator.activeSpaceID { BrowserHaptics.alignment(enabled: preferences.haptics) }
    }

    func activateSelection() {
        reconcileRuntimePresentation()
        for id in coordinator.visibleTabIDs {
            guard let tab = coordinator.tabStore.tab(id: id) else { continue }
            webViews.activate(tab)
        }
        contentFocusRequest += 1
    }

    /// Pointer focus must not steal the first responder from a clicked form
    /// field. Menu/keyboard focus uses the same target with an explicit request.
    @discardableResult
    func focusPane(_ id: UUID, restoreFocus: Bool = true) -> Bool {
        guard canPerform(.focusSplitPane(id)),
              let pane = coordinator.activeSplitGroup?.panes.first(where: { $0.id == id }) else { return false }
        guard coordinator.focusedTabID != pane.tabID else {
            if restoreFocus { contentFocusRequest += 1 }
            return true
        }
        cancelTabSwitcher(restoreFocus: false)
        cancelCommandBarQueries()
        guard coordinator.focusPane(id) else { return false }
        save()
        if restoreFocus { contentFocusRequest += 1 }
        return true
    }

    private func updateRuntimeInteraction() {
        webViews.interactionInProgress = sidebarInteractionInProgress || splitResize != nil
    }

    /// This gate intentionally allows a sidebar drag, but not a modal editor,
    /// website dialog, command bar, resize, or a settling Space transition.
    var canPreviewSplit: Bool {
        coordinator.commandBar == nil && !spaceSwipeIsSettling && splitResize == nil
            && !folderEditorIsPresented && renamingTabID == nil && spaceEditor == nil
            && spaceDeletionID == nil && !hasVisibleDialog
    }

    func updateSplitPreview(for tabID: UUID, at point: CGPoint, in bounds: CGRect, leadingInset: CGFloat = 0) {
        guard canPreviewSplit, point.x.isFinite, point.y.isFinite,
              let targets = BrowserSplitDropTargets(in: bounds, leadingInset: leadingInset), targets.content.contains(point),
              coordinator.splitPlacement(for: tabID, on: .leading) != nil else {
            cancelSplitPreview()
            return
        }
        if splitDropSourceID != tabID { splitDropSourceID = tabID }
        let next = targets.side(at: point).flatMap { coordinator.splitPlacement(for: tabID, on: $0) }
        guard next != splitPreview else { return }
        let feedback = next != nil && (splitPreview?.sourceTabID != next?.sourceTabID || splitPreview?.side != next?.side)
        splitPreview = next
        if feedback, preferences.haptics {
            if let onSplitPreviewFeedback { onSplitPreviewFeedback() }
            else { BrowserHaptics.splitPreview() }
        }
    }

    func cancelSplitPreview() {
        splitPreview = nil
        splitDropSourceID = nil
    }

    @discardableResult
    func commitSplitPreview() -> Bool {
        guard canPreviewSplit, let proposal = splitPreview else { cancelSplitPreview(); return false }
        cancelSplitPreview()
        guard coordinator.applySplit(proposal) else { return false }
        // No drop haptic. Only a committed operation can activate the new pane.
        activateSelection()
        save()
        return true
    }

    @discardableResult
    func splitTab(_ id: UUID, on side: BrowserSplitSide) -> Bool {
        guard splitGroup(containing: id) == nil,
              let proposal = coordinator.splitPlacement(for: id, on: side), coordinator.applySplit(proposal) else { return false }
        cancelSplitPreview()
        activateSelection()
        save()
        return true
    }

    func splitGroup(containing tabID: UUID) -> BrowserSplitGroup? {
        coordinator.splitGroups.first { $0.spaceID == coordinator.activeSpaceID && $0.panes.contains { $0.tabID == tabID } }
    }

    @discardableResult
    func swapSplit(_ id: UUID) -> Bool {
        guard coordinator.swapSplit(id) else { return false }
        cancelSplitPreview()
        // Both pages remain presented and the same tab/input owns focus. A swap
        // is metadata only: do not activate, navigate or recreate either page.
        save()
        return true
    }

    @discardableResult
    func removeSplitPane(_ id: UUID) -> Bool {
        guard coordinator.removeSplitPane(id) else { return false }
        activateSelection()
        save()
        return true
    }

    @discardableResult
    func exitSplit(_ id: UUID) -> Bool {
        guard coordinator.exitSplit(id) else { return false }
        activateSelection()
        save()
        return true
    }

    @discardableResult
    func resizeSplit(_ id: UUID, fraction: Double) -> Bool {
        guard coordinator.resizeSplit(id, leadingFraction: fraction) else { return false }
        save()
        return true
    }

    func beginSplitResize(_ id: UUID) {
        guard let group = coordinator.activeSplitGroup, group.id == id,
              canPerform(.resizeSplit(id, group.leadingFraction)) else { return }
        cancelTabSwitcher(restoreFocus: false)
        splitResize = SplitResize(groupID: id, fraction: group.leadingFraction)
        updateRuntimeInteraction()
    }

    func updateSplitResize(_ fraction: Double) {
        guard fraction.isFinite, let resize = splitResize, coordinator.activeSplitGroup?.id == resize.groupID else { return }
        splitResize?.fraction = min(max(fraction, BrowserSplitGroup.fractionRange.lowerBound), BrowserSplitGroup.fractionRange.upperBound)
    }

    func finishSplitResize(commit: Bool) {
        guard let resize = splitResize else { return }
        splitResize = nil
        updateRuntimeInteraction()
        if commit { _ = perform(.resizeSplit(resize.groupID, resize.fraction)) }
    }

    func cancelWindowInteractions() {
        cancelSplitPreview()
        finishSplitResize(commit: false)
        cancelTabSwitcher(restoreFocus: false)
        cancelSpaceSwipePresentation()
    }

    private func reconcileRuntimePresentation() {
        guard webViews.reconcile(tabs: coordinator.tabStore.tabs) else { return }
        _ = webViews.setPresentation(visibleTabIDs: coordinator.visibleTabIDs, focusedTabID: coordinator.focusedTabID)
    }

    func reload() { if let id = coordinator.focusedTabID { webViews.reload(id) } }
    func stop() { if let id = coordinator.focusedTabID { webViews.stop(id) } }
    func back() { if let id = coordinator.focusedTabID { webViews.back(id) } }
    func forward() { if let id = coordinator.focusedTabID { webViews.forward(id) } }
    func save() {
        validateTabSwitcher()
        validateSplitPresentation()
        reconcileRuntimePresentation()
        onSave?(self)
    }

    private func validateSplitPresentation() {
        if let source = splitDropSourceID, !canPreviewSplit || coordinator.splitPlacement(for: source, on: .leading) == nil {
            cancelSplitPreview()
        }
        if let splitPreview, coordinator.splitPlacement(for: splitPreview.sourceTabID, on: splitPreview.side) != splitPreview {
            cancelSplitPreview()
        }
        if let splitResize, coordinator.activeSplitGroup?.id != splitResize.groupID { finishSplitResize(commit: false) }
    }

    func openTabInNewWindow(_ id: UUID) {
        guard let tab = coordinator.tabStore.tab(id: id) else { return }
        let url = tab.isOpen ? tab.currentURL : (tab.pinnedURL ?? tab.currentURL)
        guard (try? input.validate(url)) != nil else { return }
        onOpenWindow?(url, tab.displayTitle)
    }

    @discardableResult
    func duplicateTab(_ id: UUID) -> UUID? {
        guard let source = coordinator.tabStore.tab(id: id) else { return nil }
        let rawURL = source.isOpen ? source.currentURL : (source.pinnedURL ?? source.currentURL)
        guard let url = try? input.validate(rawURL),
              let copyID = coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)),
              let copy = coordinator.tabStore.tab(id: copyID) else { return nil }
        webViews.load(url, in: copy)
        showNewTabToastIfNeeded()
        contentFocusRequest += 1
        save()
        return copyID
    }

    func applyProfileSnapshot(_ session: BrowserSession) {
        cancelWindowInteractions()
        cancelTabSwitcher(restoreFocus: false)
        let previous = coordinator.activeTabID
        guard coordinator.applySession(session, using: input) else { return }
        cancelSpaceSwipePresentation()
        cancelCommandBarQueries()
        let remaining = Set(session.tabs.filter(\.isOpen).map(\.id))
        for id in Array(webViews.pages.keys) where !remaining.contains(id) { webViews.discard(tabID: id) }
        renamingTabID = nil
        spaceEditor = nil
        spaceDeletionID = nil
        reconcileRuntimePresentation()
        if previous != coordinator.activeTabID { activateSelection() }
    }

    func synchronizeSavedItems(from session: BrowserSession) {
        let previous = coordinator.activeTabID
        let previousSpaces = coordinator.spaces.map(\.id)
        coordinator.synchronizeSavedItems(from: session)
        validateTabSwitcher()
        validateSplitPresentation()
        if previousSpaces != coordinator.spaces.map(\.id) { cancelSpaceSwipePresentation() }
        let remaining = Set(coordinator.tabStore.tabs.map(\.id))
        for id in Array(webViews.pages.keys) where !remaining.contains(id) { webViews.discard(tabID: id) }
        if let renamingTabID, !remaining.contains(renamingTabID) { self.renamingTabID = nil }
        if case .edit(let id, _) = spaceEditor, !coordinator.spaces.contains(where: { $0.id == id }) { spaceEditor = nil }
        if let spaceDeletionID, !coordinator.spaces.contains(where: { $0.id == spaceDeletionID }) { self.spaceDeletionID = nil }
        reconcileRuntimePresentation()
        if previous != coordinator.activeTabID { activateSelection() }
    }
}

/// One writer, with only the latest pending snapshot retained during a burst.
/// Encoding and SQLite I/O take place on SessionRepository's actor.
@MainActor @Observable
final class SessionAutosaver {
    private let repository: SessionRepository
    private let disabledReason: String?
    private var pending: BrowserWorkspace?
    private var writer: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var lastSavedAt: Date?
    var isAvailable: Bool { disabledReason == nil }

    init(repository: SessionRepository, disabledReason: String?) {
        self.repository = repository
        self.disabledReason = disabledReason
        error = disabledReason
    }

    func enqueue(_ snapshot: BrowserWorkspace) {
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
                    try await self.repository.saveWorkspace(snapshot, revision: self.revision)
                    self.error = nil
                    self.lastSavedAt = Date()
                } catch { self.error = error.localizedDescription }
            }
            self.isSaving = false
            self.writer = nil
        }
    }

    func flush() async -> Bool {
        // A callback can enqueue a new writer while this await resumes. Drain
        // that writer too before quit/deletion treats the snapshot as durable.
        while let writer { await writer.value }
        return error == nil
    }
}
