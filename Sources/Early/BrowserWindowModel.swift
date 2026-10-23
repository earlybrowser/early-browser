// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import Observation
import SwiftUI
import UniformTypeIdentifiers
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
        enum Kind { case copiedURL, newTab, downloadStarted, siteDataCleared }
        let id = UUID()
        let kind: Kind
        var message: String {
            switch kind {
            case .copiedURL: "Copied Current URL"
            case .newTab: "New Tab Created"
            case .downloadStarted: "Download Started"
            case .siteDataCleared: "Cleared Cache and Cookies"
            }
        }
        var accessibilityIdentifier: String {
            switch kind {
            case .copiedURL: "browser.copiedURL"
            case .newTab: "browser.newTabCreated"
            case .downloadStarted: "browser.downloadStarted"
            case .siteDataCleared: "browser.siteDataCleared"
            }
        }
    }
    /// A brief "125%" confirmation in the zoomed pane.
    struct ZoomNotice: Identifiable, Equatable {
        let id = UUID()
        let tabID: UUID
        let zoom: Double
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
    /// A private window: a temporary profile with a website data store kept
    /// only in memory, no history, and nothing saved or restored.
    let isPrivate: Bool
    /// This profile's browsing history; nil records nothing.
    let history: HistoryStore?
    /// This profile's per-site camera, microphone and location choices.
    let sitePermissions: SitePermissions
    /// The saved passwords this window fills from: its profile's, or for a
    /// private window the profile it was opened from. Private windows never
    /// save or change them.
    let passwords: PasswordVault?
    let passwordsProfileID: UUID?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The address last recorded per tab, and the live page it came from.
    @ObservationIgnored private var historyURLs: [UUID: (url: URL, page: UUID)] = [:]
    @ObservationIgnored private var historyQueue: Task<Void, Never>?
    var submissionMessage: String?
    var commandBarIsComposing = false
    var notice: String?
    var toast: Toast?
    var downloadsPresented = false
    var zoomNotice: ZoomNotice?
    /// What Paste and Go would do with the clipboard, without reading it; nil
    /// hides the item because the clipboard holds no text.
    enum PasteKind: Equatable {
        case address, search
        var title: String { self == .address ? "Paste and Go" : "Paste and Search" }
    }
    private(set) var pasteKind: PasteKind?
    @ObservationIgnored private var pasteKindChangeCount = -1
    /// Show All History, and its Clear History choices.
    var historyPresented = false
    var clearHistoryPresented = false
    /// Bumped when history or website data was cleared, so History reloads.
    var historyRevision = 0
    /// The pages most recently visited in this profile, newest first, for the
    /// History menu; see `recentlyVisited`.
    private(set) var recentPages: [HistoryPage] = []
    static let recentPageLimit = 15
    /// Tabs whose language Apple's Translation can turn into the user's.
    var translationOffers: [UUID: TranslationOffer] = [:]
    /// The translation waiting for (or running in) the window's session.
    var translationRequest: TranslationRequest?
    /// Command-F focuses the focused pane's find field, even if already open.
    var findFocusRequest = 0
    /// Early's download icon flying from the clicked page point to the button.
    struct DownloadFlight: Identifiable, Equatable {
        let id = UUID()
        let start: CGPoint
        let end: CGPoint
    }
    private(set) var downloadFlight: DownloadFlight?
    /// Increments when a flight lands, so the button can react on arrival.
    private(set) var downloadLandingRevision = 0
    /// The Downloads button's frame in the window's top-left coordinate space.
    var downloadsButtonFrame: CGRect?
    @ObservationIgnored private var lastPagePress: (point: CGPoint, time: Date)?
    @ObservationIgnored var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Open File is a window-level sheet; page sheets use the page's dialog state.
    var documentPanelIsPresented = false
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
        // Private windows need both settings; the private one is off by default.
        get { preferences.onlineSuggestions && (!isPrivate || preferences.privateOnlineSuggestions) }
        set { preferences.onlineSuggestions = newValue; refreshSuggestions() }
    }
    var commandBarActionsEnabled: Bool {
        get { preferences.commandBarActions }
        set { preferences.commandBarActions = newValue; refreshSuggestions() }
    }

    init(startup: StartupContext, session: BrowserSession, repository: SessionRepository,
         input: NavigationInput, isTesting: Bool, restorationError: String?, defaults: UserDefaults = .standard,
         sharedPersistence: SessionAutosaver? = nil, websiteDataStore: WKWebsiteDataStore? = nil,
         downloads: DownloadStore? = nil, preferences: BrowserPreferences? = nil, isPrivate: Bool = false,
         history: HistoryStore? = nil, sitePermissions: SitePermissions? = nil,
         passwords: PasswordVault? = nil, passwordsProfileID: UUID? = nil,
         searchProviders: [any CommandSearchProvider] = [],
         configureWebView: ((WKWebViewConfiguration) -> Void)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.input = input
        self.isTesting = isTesting
        self.isPrivate = isPrivate
        self.history = isPrivate ? nil : history
        self.sitePermissions = sitePermissions ?? SitePermissions(fileURL: nil)
        self.passwords = passwords
        self.passwordsProfileID = passwords == nil ? nil : passwordsProfileID ?? (isPrivate ? nil : session.profileID)
        self.now = now
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
        commandSearch = CommandSearch(providers: searchProviders + (history.map { [HistorySearchProvider(store: $0)] } ?? []),
                                      now: now)
        coordinator = BrowserCoordinator(startup: startup, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), selectionBySpace: session.selectionBySpace,
            profileID: session.profileID, recentlyClosed: session.recentlyClosed, spaces: session.spaces,
            splitGroups: session.splitGroups, focusedPaneByGroupID: session.focusedPaneByGroupID, now: now)
        persistence = sharedPersistence ?? SessionAutosaver(repository: repository, disabledReason: restorationError)
        // Tests drive pressure explicitly; host resource usage must not change
        // which fixture pages survive while assertions are running.
        webViews = WebViewManager(profileID: session.profileID, ephemeral: isTesting || isPrivate, input: input,
                                 websiteDataStore: websiteDataStore,
                                 downloads: downloads ?? (isTesting ? DownloadStore(directory: FileManager.default.temporaryDirectory
                                    .appending(path: "EarlyTestDownloads/\(UUID().uuidString)", directoryHint: .isDirectory)) : nil),
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
            guard let self else { return }
            // A pin or Favorite reopened at its saved address changes none of
            // its metadata, but it is still a visit.
            if self.coordinator.tabStore.tab(id: id)?.isOpen == true { self.recordHistory(id, url: url, title: title) }
            guard self.coordinator.updateMetadata(id, url: url, title: title) else { return }
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
        webViews.onDownloadStarted = { [weak self] _ in
            guard let self else { return }
            // The footer shows progress; confirm only when the sidebar is hidden.
            if self.sidebarIsHidden { self.showToast(.downloadStarted) }
            self.beginDownloadFlight()
        }
        webViews.onOpenFiles = { [weak self] in _ = self?.openLocations($0) }
        webViews.onViewPageSource = { [weak self] in self?.showPageSource($0) }
        webViews.sitePermissions = self.sitePermissions
        webViews.passwords = passwords
        webViews.savesPasswords = !isPrivate
        webViews.onManagePasswords = { [weak self] host in self?.showPasswords(search: host) }
        webViews.automaticPictureInPicture = { [weak self] in self?.preferences.automaticPictureInPicture == true }
        webViews.onPageLanguage = { [weak self] id, language in self?.updateTranslationOffer(id, language: language) }
        webViews.translationMenuTitle = { [weak self] in self?.translationTitle(for: $0) }
        webViews.onTranslatePage = { [weak self] in self?.toggleTranslation($0) }
        webViews.onOpenSearch = { [weak self] text in
            guard let self, let url = try? self.input.searchURL(for: text) else { return }
            _ = self.openLocations([url])
        }
        activateSelection()
        if coordinator.activeTabID == nil { coordinator.presentCommandBar(.newTab) }
        refreshRecentPages()
        // The app installs the shared writer before publishing the first snapshot.
    }

    var activePage: BrowserPage? { coordinator.focusedTabID.flatMap { webViews.pages[$0] } }
    var downloads: DownloadStore { webViews.downloads }

    /// Checks the clipboard's kind when it changed. Types and detected patterns
    /// are metadata: reading them never shows macOS's paste permission alert.
    func refreshPasteKind(_ pasteboard: NSPasteboard = .general) {
        let change = pasteboard.changeCount
        guard change != pasteKindChangeCount else { return }
        pasteKindChangeCount = change
        guard pasteboard.types?.contains(.string) == true else {
            pasteKind = nil
            return
        }
        if #available(macOS 15.4, *) {
            if pasteKind == nil { pasteKind = .search }
            let name = pasteboard.name
            Task { @MainActor [weak self] in
                let isAddress = await Task.detached {
                    let patterns = try? await NSPasteboard(name: name).detectedPatterns(for: [\.probableWebURL])
                    return patterns?.contains(\.probableWebURL) == true
                }.value
                guard let self, self.pasteKindChangeCount == change else { return }
                self.pasteKind = isAddress ? .address : .search
            }
        } else {
            // Before macOS 15.4 only reading could tell, and hovering is not a
            // reason to read the clipboard. Chosen text still searches.
            pasteKind = .address
        }
    }

    func pasteKind(for query: String) -> PasteKind {
        guard let url = try? input.resolve(query), let search = try? input.searchURL(for: query) else { return .search }
        return url == search ? .search : .address
    }

    /// Paste and Go / Paste and Search: the clipboard is read only now, when
    /// chosen, and submitted exactly like a typed query. With an intent it opens
    /// the command bar for it (the address pill); otherwise it uses the open
    /// one. An address Early refuses stays in the bar with its message.
    @discardableResult
    func pasteAndGo(_ intent: CommandBarIntent? = nil, pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = pasteboard.string(forType: .string), let query = NavigationInput.pastedQuery(text) else { return false }
        if let intent {
            guard canPerform(.presentCommandBar(intent)) else { return false }
            presentCommandBar(intent)
        }
        guard coordinator.commandBar != nil, coordinator.commandBar?.intent != .commandSearch else { return false }
        updateQuery(query)
        return submit()
    }

    /// Escape or the close button: the match stays selected and the page,
    /// not the sidebar, gets keyboard focus back.
    func closeFind(_ id: UUID) {
        webViews.hideFind(id)
        if id == coordinator.focusedTabID { contentFocusRequest += 1 }
    }

    /// Reader's links and accents in the active Space's theme. Reader follows
    /// the page's appearance, so private windows use the neutral Space gray.
    var readerAccent: ReaderAccent {
        let theme = isPrivate ? .space(.gray) : chromeTheme
        return ReaderAccent(light: theme.focusBorder(isDark: false).hex, dark: theme.focusBorder(isDark: true).hex)
    }

    /// Show or leave Reader; focus follows to Reader's view or back to the page.
    func toggleReader(_ id: UUID) {
        guard let page = webViews.pages[id] else { return }
        if page.isReaderShown {
            webViews.hideReader(id)
            if id == coordinator.focusedTabID { contentFocusRequest += 1 }
            return
        }
        Task { @MainActor [weak self] in
            guard let self, await self.webViews.showReader(id, accent: self.readerAccent),
                  id == self.coordinator.focusedTabID else { return }
            self.contentFocusRequest += 1
        }
    }

    func useSelectionForFind(in id: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let text = await self.webViews.findSelection(id),
                  self.webViews.showFind(id) else { return }
            self.webViews.updateFind(id, query: text)
            self.findFocusRequest += 1
        }
    }

    func recordPagePress(at point: CGPoint, time: Date = Date()) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lastPagePress = (point, time)
    }

    /// Only a download that follows a recent page click flies, and only to a
    /// visible Downloads button. Menu-started saves and Reduce Motion do not.
    func beginDownloadFlight(now: Date = Date()) {
        defer { lastPagePress = nil }
        guard let press = lastPagePress, now.timeIntervalSince(press.time) <= 4, now >= press.time,
              !sidebarIsHidden, !prefersReducedMotion(), let target = downloadsButtonFrame,
              target.width > 0, target.height > 0 else { return }
        downloadFlight = DownloadFlight(start: press.point, end: CGPoint(x: target.midX, y: target.midY))
    }

    func finishDownloadFlight(_ id: UUID) {
        guard downloadFlight?.id == id else { return }
        downloadFlight = nil
        downloadLandingRevision += 1
    }

    /// Dropped/opened files and addresses become new Today tabs in this Space;
    /// they never replace a pinned or saved page. Each must be a valid address.
    @discardableResult
    func openLocations(_ urls: [URL]) -> Bool {
        let valid = urls.compactMap { try? input.validate($0) }.prefix(10)
        guard !valid.isEmpty else { return false }
        if coordinator.commandBar != nil { dismissCommandBar(restoreFocus: false) }
        for url in valid {
            guard let id = coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)),
                  let tab = coordinator.tabStore.tab(id: id) else { continue }
            webViews.load(url, in: tab)
        }
        notice = nil
        contentFocusRequest += 1
        save()
        return true
    }

    func presentOpenFilePanel() {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html, .pdf, .image, .plainText, .webArchive, .svg]
        panel.prompt = "Open"
        documentPanelIsPresented = true
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.documentPanelIsPresented = false
            guard response == .OK, let urls = panel?.urls else { return }
            self.openLocations(urls)
        }
    }
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

    /// The focused page's website, whose permissions Site Controls shows.
    var currentSiteOrigin: String? { currentPageURL.flatMap(SitePermissions.origin(of:)) }

    func sitePermission(_ permission: SitePermission) -> SitePermissionDecision? {
        currentSiteOrigin.map { sitePermissions.decision(for: $0, permission) }
    }

    /// Clear Cache and Cookies asks first: the website it would clear.
    var siteDataClearRequest: String?

    /// Removes the website's data from this profile, then reloads its tabs in
    /// this window so they start signed out, as a fresh visit would.
    func clearSiteData(_ host: String) async {
        siteDataClearRequest = nil
        await webViews.clearWebsiteData(forHost: host)
        for (id, page) in webViews.pages {
            if let pageHost = page.view.url?.host, WebViewManager.dataRecord(host, belongsTo: pageHost) { webViews.reload(id) }
        }
        showToast(.siteDataCleared)
    }

    /// Whether the focused tab's Web Inspector is open, for menu titles.
    var isWebInspectorVisible: Bool { coordinator.focusedTabID.map { webViews.isWebInspectorVisible($0) } == true }

    /// The page's current markup in a new tab beside it, at `view-source:`.
    func showPageSource(_ id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let address = await self.webViews.capturePageSource(id), self.openLocations([address]) else {
                self.notice = "The page’s source couldn’t be shown."
                return
            }
        }
    }

    /// Settings › Passwords for this window's profile.
    func showPasswords(search host: String?) {
        application?.showPasswords(profileID: passwordsProfileID, search: host)
    }

    /// How many passwords are saved for the focused website, once they're
    /// open; nil before that, so showing Site Controls never asks the Keychain.
    var savedPasswordCount: Int? {
        guard let passwords, passwords.isReady, let origin = currentSiteOrigin else { return nil }
        return passwords.logins(for: origin).count
    }

    /// Blocking a camera or microphone in use stops it in the site's tabs.
    func setSitePermission(_ permission: SitePermission, _ decision: SitePermissionDecision) {
        guard let origin = currentSiteOrigin else { return }
        sitePermissions.set(decision, for: [permission], origin: origin)
        webViews.applySitePermissions()
    }

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

    func showToast(_ kind: Toast.Kind) {
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
        // A private window has no saved pages to place a tab among.
        guard !isPrivate || section == .regular, coordinator.placeTab(id, in: section, folderID: folderID, before: before) else { return false }
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

    /// A new address in a tab, or the same one in a newly loaded page (a
    /// reopened pin), is a visit; a later title for it only names it. One
    /// serial queue keeps a title from preceding its visit.
    private func recordHistory(_ id: UUID, url: URL?, title: String?) {
        guard let history, let url, HistoryStore.records(url), let page = webViews.pages[id] else { return }
        let previous = historyQueue
        let identity = page.instanceID
        if let last = historyURLs[id], last.url == url, last.page == identity {
            guard let title, !title.isEmpty else { return }
            historyQueue = Task { await previous?.value; try? await history.updateTitle(url, title: title) }
            refreshRecentPages()
        } else {
            if historyURLs.count > 500 {
                let open = Set(coordinator.tabStore.tabs.filter(\.isOpen).map(\.id))
                historyURLs = historyURLs.filter { open.contains($0.key) }
            }
            historyURLs[id] = (url, identity)
            let date = now()
            historyQueue = Task { await previous?.value; try? await history.record(url, title: title, at: date) }
            refreshRecentPages()
        }
    }

    /// Pages visited today, newest first: History's menu lists them.
    var recentlyVisited: [HistoryPage] {
        let today = Calendar.current.startOfDay(for: now())
        return recentPages.filter { $0.lastVisit >= today }
    }

    /// Reloads the History menu's pages after the visits already queued.
    func refreshRecentPages() {
        guard let history else { return }
        let previous = historyQueue
        let since = Calendar.current.startOfDay(for: now())
        historyQueue = Task { [weak self] in
            await previous?.value
            let pages = (try? await history.recentPages(since: since, limit: Self.recentPageLimit)) ?? []
            guard let self, self.recentPages != pages else { return }
            self.recentPages = pages
            // Their site icons, from the cache when possible, for the menu.
            for page in pages { self.webViews.favicons.request(page.url) }
        }
    }

    /// The addresses of this window's tabs, pins and Favorites, open or not.
    var sidebarURLs: [URL] { coordinator.tabStore.tabs.flatMap { [$0.currentURL, $0.pinnedURL].compactMap { $0 } } }

    /// Waits for recorded visits to reach the store (tests and clearing).
    func flushHistory() async { await historyQueue?.value }

    /// Clears this profile's history and website data from the period's start,
    /// with cached icons and thumbnails in every window of the profile.
    func clearHistory(_ range: HistoryClearRange) async {
        let since = range.start(now: now())
        await flushHistory()
        try? await history?.deleteVisits(since: since)
        // Tabs, pins and Favorites in every window of the profile keep their icons.
        let kept = application?.sidebarURLs(profileID: coordinator.profileID) ?? sidebarURLs
        await webViews.clearWebsiteData(since: since, keepingIconsFor: kept)
        // Open tabs keep their last recorded page: a title arriving later only
        // names a page that is gone, and does not put it back in History.
        historyRevision += 1
        refreshRecentPages()
        application?.didClearWebsiteData(profileID: coordinator.profileID, from: self)
    }

    /// Closes several Today tabs at once, keeping their pages reopenable.
    func closeTodayTabs(_ ids: [UUID], keeping kept: UUID? = nil) {
        let previousActive = coordinator.activeTabID
        let previousVisible = coordinator.visibleTabIDs
        let closed = coordinator.closeTodayTabs(ids, keeping: kept)
        guard !closed.isEmpty else { return }
        for id in closed { webViews.discard(tabID: id) }
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

    func reopenClosedTab(_ id: UUID) {
        guard coordinator.reopenClosedTab(id) != nil else { return }
        activateSelection()
        save()
    }

    /// History › Recently Closed: this window's closed tabs, newest first.
    var recentlyClosedTabs: [BrowserTab] {
        coordinator.recentlyClosed.reversed().map(\.tab).filter { canPerform(.reopenRecentlyClosedTab($0.id)) }
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
        !isPrivate && !spaceSwipeIsSettling && !sidebarInteractionInProgress && splitResize == nil && !folderEditorIsPresented && !hasVisibleDialog
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
            commitSpaceSwipe(to: target, action: action)
            return
        }
        let revision = UUID()
        spaceSwipeRevision = revision
        spaceSwipeIsSettling = true
        let settleDuration = target == nil ? SpaceSwitchMotion.cancellationSettleDuration : SpaceSwitchMotion.navigationSettleDuration
        withAnimation(.easeOut(duration: settleDuration)) {
            spaceSwipeProgress = target == nil ? 0 : (delta > 0 ? -1 : 1)
            spaceSwipeCreationProgress = 0
        }
        spaceSwipeSettleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(settleDuration)) } catch { return }
            guard let self, self.spaceSwipeRevision == revision else { return }
            let contextMatches = self.coordinator.activeSpaceID == source && self.coordinator.spaces.map(\.id) == catalog
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.spaceSwipeIsSettling = false
                self.spaceSwipeSettleTask = nil
                self.spaceSwipeProgress = 0
            }
            // Only reset the sidebar's finished travel without animation.
            // Committing the Space outside that transaction lets the content
            // perform the same fade as a dot/menu/keyboard Space selection.
            guard contextMatches, self.canManageSpaces else { return }
            self.commitSpaceSwipe(to: target, action: action)
        }
    }

    /// Mark the commit so the footer indicator, already at the destination,
    /// does not replay its selection animation from the reset swipe travel.
    private func commitSpaceSwipe(to target: UUID?, action: SpaceSwipe.Action?) {
        var commit = Transaction()
        commit.isSpaceSwipeCommit = true
        withTransaction(commit) {
            if let target { _ = switchSpace(to: target) }
            else if action == .create { requestNewSpace() }
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

    /// The chrome, drop targets and focused pane share the current Space's
    /// theme. Private windows are always gray, with or without Space themes.
    var chromeTheme: WindowTheme {
        isPrivate ? .privateBrowsing : .space(preferences.spaceThemes ? (coordinator.activeSpace?.color ?? .gray) : .gray)
    }

    /// Whether floating chrome, such as the command bar, wears the theme.
    var tintsChrome: Bool { isPrivate || preferences.spaceThemes }

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
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            splitResize = SplitResize(groupID: id, fraction: group.leadingFraction)
            updateRuntimeInteraction()
        }
    }

    func updateSplitResize(_ fraction: Double) {
        guard fraction.isFinite, let resize = splitResize, coordinator.activeSplitGroup?.id == resize.groupID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            splitResize?.fraction = min(max(fraction, BrowserSplitGroup.fractionRange.lowerBound), BrowserSplitGroup.fractionRange.upperBound)
        }
    }

    func finishSplitResize(commit: Bool) {
        guard let resize = splitResize else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            splitResize = nil
            updateRuntimeInteraction()
            if commit { _ = perform(.resizeSplit(resize.groupID, resize.fraction)) }
        }
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
