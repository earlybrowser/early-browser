// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import Observation
import WebKit

@MainActor @Observable
public final class WebViewManager: NSObject, WKNavigationDelegate, WKUIDelegate {
    public private(set) var pages: [UUID: BrowserPage] = [:]
    public private(set) var creationCount = 0
    public private(set) var lifecycles: [UUID: PageLifecycle] = [:]
    public private(set) var visibleTabIDs: Set<UUID> = []
    public private(set) var focusedTabID: UUID?
    public let favicons: FaviconStore
    public let snapshots: PageSnapshotCache
    /// Shared by every window of this profile and owned by the application.
    public let downloads: DownloadStore
    public private(set) var retentionPolicy: PageRetentionPolicy
    /// Browser-owned interactions can temporarily defer eviction. Individual
    /// protection tokens let future download owners protect their source tab.
    public var interactionInProgress = false {
        didSet { if !interactionInProgress { scheduleRetention() } }
    }
    public enum Protection: Hashable, Sendable { case interaction, download }
    var protections: [UUID: [UUID: Protection]] = [:]
    private var muteChoices: Set<UUID> = []
    /// Zoom belongs to the tab, so it survives background discard and recovery.
    var zoomChoices: [UUID: Double] = [:]
    /// Shared by this profile's tabs, like Safari's find string.
    var lastFindQuery = ""
    /// Reader's separate views, keyed by the tab they belong to.
    var readerViews: [UUID: WKWebView] = [:]
    public var onMetadata: ((UUID, URL?, String?) -> Void)?
    public var onNewWindow: ((URL, WKWebViewConfiguration) -> WKWebView?)?
    public var onOpenBackgroundLink: ((URL) -> Void)?
    public var onOpenWindowLink: ((URL) -> Void)?
    public var onClose: ((UUID) -> Void)?
    public var onNotice: ((String) -> Void)?
    public var onDownloadStarted: ((DownloadItem) -> Void)?
    /// Local files from an unhandled page drop open as new tabs, never in place.
    public var onOpenFiles: (([URL]) -> Void)?
    /// A selected-text search opens a new foreground tab.
    public var onOpenSearch: ((String) -> Void)?
    /// A page's detected language changed (nil: a new document is loading).
    public var onPageLanguage: ((UUID, String?) -> Void)?
    /// The page menu's Translate title, from the window; nil leaves it out.
    public var translationMenuTitle: ((UUID) -> String?)?
    /// Translate or Show Original was chosen from the page menu.
    public var onTranslatePage: ((UUID) -> Void)?
    /// The profile's per-site permission choices; nil denies every request.
    public var sitePermissions: SitePermissions?
    /// Picture in Picture's return button was clicked: the owner shows this
    /// tab (its Space and window), and WebKit then returns the video to it.
    public var onReturnFromPictureInPicture: ((UUID) -> Void)?
    /// Whether a tab switched away from keeps its playing video in Picture in Picture.
    public var automaticPictureInPicture: () -> Bool = { false }
    /// Tabs whose video Early is moving, or moved, into Picture in Picture.
    @ObservationIgnored var automaticPictureInPictureTabs: [UUID: AutomaticPictureInPicture] = [:]
    /// This window's `view-source:` snapshots.
    let sourcePages = PageSourcePages()
    /// View Page Source was chosen from a page's menu.
    public var onViewPageSource: ((UUID) -> Void)?
    /// The saved passwords this window fills from; nil fills and saves nothing.
    public var passwords: PasswordVault?
    /// Private windows fill saved passwords but never save or change them.
    public var savesPasswords = true
    /// The window's look for the list under sign-in fields.
    public var passwordListStyle: () -> PasswordListStyle = { PasswordListStyle(theme: .space(.gray), allowsTransparency: true) }
    /// The profile's extensions (a `WKWebExtensionController` on macOS 15.4
    /// and later); pages get it when they're created.
    public var extensionController: AnyObject?
    /// Extensions' menu items for a tab's page.
    public var extensionMenuItems: ((UUID) -> [NSMenuItem])?
    /// An extension's keyboard shortcut.
    public var extensionCommand: ((NSEvent) -> Bool)?
    /// An extension's own pages (options, pages it opens) load only in a view
    /// made from its context's configuration: the one for an address, if any.
    public var extensionPageConfiguration: ((URL) -> WKWebViewConfiguration?)?
    /// An extension page follows a link out to the web: the owner replaces its
    /// privileged view with an ordinary one. Never used to enter an extension.
    public var onNeedsNewView: ((UUID, URL) -> Void)?
    /// The search engine a page's "Search with…" item names.
    public var searchEngineName: () -> String = { SearchEngine.google.name }

    /// "scheme://host" of an extension's page; nil for anything else.
    public static func extensionOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), NavigationInput.extensionSchemes.contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }
    /// Manage Passwords… was chosen under a sign-in field, for this host.
    public var onManagePasswords: ((String?) -> Void)?
    /// Answers "Allow downloads?" for a host instead of Early's sheet (nil: dismissed); tests use it.
    @ObservationIgnored var askForDownloads: ((String, @escaping @MainActor (Bool?) -> Void) -> Void)?
    /// Answers HTTP sign-in requests instead of Early's sheet; tests use it.
    @ObservationIgnored var askForSignIn: ((SignInRequest, WKWebView, @escaping @MainActor (SignInResponse?) -> Void) -> Void)?
    /// Other schemes whose pages tests treat as websites for passwords.
    @ObservationIgnored var passwordTestSchemes: Set<String> = []
    let passwordPanel = PasswordSuggestionPanel()
    @ObservationIgnored var focusedPasswordField: FocusedPasswordField?
    @ObservationIgnored var passwordPanelField: FocusedPasswordField?
    /// Lets local files the person opened open again after a restart; nil in tests.
    @ObservationIgnored public var localFiles: LocalFileBookmarks?
    /// The app macOS would open a link with, and opening it; tests replace both.
    @ObservationIgnored var appForLink: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    @ObservationIgnored var openInApp: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Runs a page script and reports whether it returned true; tests observe it.
    @ObservationIgnored var runPageScript: (WKWebView, String, WKFrameInfo?) async -> Bool = { view, script, frame in
        (try? await view.callAsyncJavaScript(script, in: frame, contentWorld: .defaultClient)) as? Bool == true
    }
    let profileID: UUID
    let ephemeral: Bool
    let input: NavigationInput
    private let configure: (WKWebViewConfiguration) -> Void
    private var store: WKWebsiteDataStore?
    var identities: [ObjectIdentifier: UUID] = [:]
    var dialogs: [UUID: PendingDialog] = [:]
    var documentPanels: [UUID: PendingPanel] = [:]
    private var controllerOwners: [ObjectIdentifier: Set<UUID>] = [:]
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var memoryMonitor: PageMemoryPressureMonitor?
    private var pressure: PageRetentionPolicy.Pressure = .normal
    // Diagnostic work counts do not trigger SwiftUI observation or record URLs.
    struct WorkMetrics {
        var retentionPasses = 0
        var inspectedPages = 0
        var presentationVisits = 0
    }
    @ObservationIgnored private(set) var workMetrics = WorkMetrics()
    @ObservationIgnored public internal(set) var navigationDiagnostics: [NavigationDiagnostic] = []

    public init(profileID: UUID, ephemeral: Bool = false,
                input: NavigationInput = NavigationInput(),
                faviconStore: FaviconStore? = nil,
                websiteDataStore: WKWebsiteDataStore? = nil,
                retentionPolicy: PageRetentionPolicy = PageRetentionPolicy(),
                snapshotCache: PageSnapshotCache? = nil,
                downloads: DownloadStore? = nil,
                observesMemoryPressure: Bool = true,
                configure: @escaping (WKWebViewConfiguration) -> Void = { _ in }) {
        self.profileID = profileID
        self.favicons = faviconStore ?? FaviconStore(profileID: profileID, ephemeral: ephemeral)
        self.downloads = downloads ?? DownloadStore()
        self.retentionPolicy = retentionPolicy
        self.snapshots = snapshotCache ?? PageSnapshotCache(profileID: profileID)
        self.ephemeral = ephemeral
        self.input = input
        self.configure = configure
        self.store = websiteDataStore
        precondition(snapshotCache == nil || snapshotCache?.profileID == profileID, "Snapshots belong to one profile")
        super.init()
        // Resuming uses this profile's cookies and storage, never another's.
        if self.downloads.dataStoreProvider == nil {
            self.downloads.dataStoreProvider = { [weak self] in self?.websiteDataStore }
        }
        if observesMemoryPressure {
            memoryMonitor = PageMemoryPressureMonitor { [weak self] pressure in
                Task { @MainActor [weak self] in self?.handleMemoryPressure(pressure) }
            }
        }
    }

    public var liveViewCount: Int { pages.count }
    public var websiteDataStore: WKWebsiteDataStore {
        if store == nil { store = ephemeral ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: profileID) }
        return store!
    }
    public func existingView(for id: UUID) -> WKWebView? { pages[id]?.view }
    func tabID(for view: WKWebView) -> UUID? { identities[ObjectIdentifier(view)] }
    public func lifecycle(for id: UUID) -> PageLifecycle { lifecycles[id] ?? PageLifecycle() }
    var registeredControllerCount: Int { controllerOwners.count }

    /// Register/prune lightweight runtime identities without preparing any view.
    /// Closed pins remain metadata only; deleted tabs leave no runtime tombstone.
    @discardableResult
    public func reconcile(tabs: [BrowserTab]) -> Bool {
        guard tabs.allSatisfy({ $0.profileID == profileID }), Set(tabs.map(\.id)).count == tabs.count else { return false }
        let all = Set(tabs.map(\.id)), open = Set(tabs.filter(\.isOpen).map(\.id))
        for id in Array(pages.keys) where !open.contains(id) { discard(tabID: id) }
        for id in Array(lifecycles.keys) where !all.contains(id) { lifecycles[id] = nil }
        retentionPolicy.reconcile(tabIDs: all)
        snapshots.retain(tabIDs: open)
        navigationDiagnostics.removeAll { !open.contains($0.tabID) }
        protections = protections.filter { open.contains($0.key) }
        muteChoices.formIntersection(open)
        zoomChoices = zoomChoices.filter { open.contains($0.key) }
        for id in all where lifecycles[id] == nil { lifecycles[id] = PageLifecycle() }
        if let focusedTabID, open.contains(focusedTabID) {
            _ = setPresentation(visibleTabIDs: visibleTabIDs.intersection(open), focusedTabID: focusedTabID)
        } else {
            _ = setPresentation(visibleTabIDs: [], focusedTabID: nil)
        }
        return true
    }

    /// Visibility/focus are window-local; unloaded tabs stay metadata-only.
    /// Existing terminated pages may recover when made visible. Every selected
    /// split member is protected, not just the focused command target.
    @discardableResult
    public func setPresentation(visibleTabIDs: Set<UUID>, focusedTabID: UUID?) -> Bool {
        guard visibleTabIDs.allSatisfy({ lifecycles[$0] != nil }),
              focusedTabID.map({ visibleTabIDs.contains($0) }) ?? visibleTabIDs.isEmpty else { return false }
        let affected = self.visibleTabIDs.union(visibleTabIDs)
        let unchanged = self.visibleTabIDs == visibleTabIDs && self.focusedTabID == focusedTabID
        if unchanged {
            for id in visibleTabIDs where pages[id]?.processTerminated == true { recoverIfNeeded(id) }
            return true
        }
        if let field = focusedPasswordField, field.tabID != focusedTabID || !visibleTabIDs.contains(field.tabID) {
            hidePasswordSuggestions()
        }
        updateAutomaticPictureInPicture(hidden: self.visibleTabIDs.subtracting(visibleTabIDs),
                                        shown: visibleTabIDs.subtracting(self.visibleTabIDs))
        for id in self.visibleTabIDs.subtracting(visibleTabIDs) { captureSnapshot(id) }
        for id in visibleTabIDs.subtracting(self.visibleTabIDs) { retentionPolicy.recordUse(of: id) }
        if let focusedTabID, focusedTabID != self.focusedTabID { retentionPolicy.recordUse(of: focusedTabID) }
        if self.visibleTabIDs != visibleTabIDs { self.visibleTabIDs = visibleTabIDs }
        if self.focusedTabID != focusedTabID { self.focusedTabID = focusedTabID }
        // Only the previous/new visible members can change presentation. A
        // metadata catalog with hundreds of unloaded tabs needs no full scan.
        for id in affected where lifecycles[id] != nil {
            workMetrics.presentationVisits += 1
            var runtime = lifecycles[id]!
            runtime.setPresentation(visible: visibleTabIDs.contains(id), focused: id == focusedTabID)
            if lifecycles[id] != runtime { lifecycles[id] = runtime }
        }
        for id in visibleTabIDs where pages[id]?.processTerminated == true { recoverIfNeeded(id) }
        scheduleRetention()
        return true
    }

    func scheduleRetention() {
        guard retentionTask == nil else { return }
        // Selection, metadata reconciliation and activation form one operation.
        // Wait until they all publish before deciding which page is background.
        retentionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.retentionTask = nil
            self.enforceRetention()
        }
    }

    @discardableResult
    public func enforceRetention() -> [UUID] {
        workMetrics.retentionPasses += 1
        guard !interactionInProgress else { return [] }
        // Below the allowance, protections cannot change the eviction result.
        // Count lightweight identities before querying native media/capture UI.
        let inactiveCount = pages.keys.lazy.filter { !self.visibleTabIDs.contains($0) }.count
        guard inactiveCount > retentionPolicy.inactiveAllowance(for: pressure) else { return [] }
        let candidates = pages.map { id, page in
            PageRetentionPolicy.Page(id: id, lifecycle: lifecycle(for: id), protections: retentionProtections(page, id: id))
        }
        let evicted = retentionPolicy.discardCandidates(from: candidates, pressure: pressure)
        var released: [UUID] = []
        for id in evicted {
            guard let page = pages[id] else { continue }
            // Commit the most recent public URL/title before releasing the page;
            // restoration uses durable metadata, never a captured DOM/history.
            refresh(id)
            // Metadata callbacks may select, close, protect, or replace a page.
            // Revalidate after calling the application before touching its view.
            guard pages[id] === page, !interactionInProgress, !visibleTabIDs.contains(id), focusedTabID != id,
                  lifecycle(for: id).state != .loading, retentionProtections(page, id: id).isEmpty else { continue }
            releasePage(tabID: id, preservingSnapshot: true)
            released.append(id)
        }
        return released
    }

    private func retentionProtections(_ page: BrowserPage, id: UUID) -> PageRetentionPolicy.Protection {
        workMetrics.inspectedPages += 1
        var protected: PageRetentionPolicy.Protection = []
        if page.isLoading || page.view.isLoading { protected.insert(.interaction) }
        if page.isPlayingMedia || page.view.fullscreenState != .notInFullscreen
            || page.view.cameraCaptureState != .none || page.view.microphoneCaptureState != .none { protected.insert(.media) }
        if page.hasDialog || page.hasUnsavedInput || (page.view as? BrowserWebView)?.hasActiveInteraction == true
            || protections[id]?.values.contains(.interaction) == true { protected.insert(.interaction) }
        if protections[id]?.values.contains(.download) == true { protected.insert(.download) }
        return protected
    }

    public func handleMemoryPressure(_ pressure: PageRetentionPolicy.Pressure) {
        self.pressure = pressure
        if pressure != .normal { snapshots.clear() }
        _ = enforceRetention()
    }

    /// Independently owned leases cannot accidentally clear another download's
    /// protection. Releasing a stale/closed-tab lease is harmless.
    @discardableResult
    public func protect(tabID: UUID, reason: Protection) -> UUID? {
        guard pages[tabID] != nil else { return nil }
        let token = UUID()
        protections[tabID, default: [:]][token] = reason
        return token
    }

    public func releaseProtection(tabID: UUID, token: UUID) {
        protections[tabID]?[token] = nil
        if protections[tabID]?.isEmpty == true { protections[tabID] = nil }
        scheduleRetention()
    }

    func captureSnapshot(_ id: UUID) {
        guard pressure == .normal, let page = pages[id], !page.isLoading,
              page.failure == nil, !page.hasUnsavedInput, !page.hasDialog,
              page.view.bounds.width > 0, page.view.bounds.height > 0 else { return }
        snapshots.request(tabID: id, navigationID: page.navigationGeneration, view: page.view)
    }

    func transition(_ id: UUID, _ event: PageLifecycle.Event) {
        var runtime = lifecycle(for: id)
        if runtime.transition(event) { lifecycles[id] = runtime }
    }

    /// Called by accepted navigation/selection, never by SwiftUI rendering.
    @discardableResult
    public func prepare(_ tab: BrowserTab, configuration supplied: WKWebViewConfiguration? = nil,
                        loading url: URL? = nil) -> BrowserPage {
        precondition(tab.profileID == profileID, "A manager owns exactly one profile")
        if let page = pages[tab.id] { return page }
        let configuration: WKWebViewConfiguration
        let extensionOrigin = Self.extensionOrigin(of: url ?? tab.currentURL)
        var hasExtensionConfiguration = false
        if let supplied {
            // WebKit requires the exact supplied configuration for window.open.
            configuration = supplied
            hasExtensionConfiguration = extensionOrigin != nil
        } else {
            if extensionOrigin != nil, let own = extensionPageConfiguration?(url ?? tab.currentURL) {
                configuration = own
                // Its copies share one; Early's message handlers stay this page's.
                configuration.userContentController = WKUserContentController()
                hasExtensionConfiguration = true
            } else {
                configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = websiteDataStore
            }
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isElementFullscreenEnabled = true
            configuration.setURLSchemeHandler(sourcePages, forURLScheme: NavigationInput.pageSourceScheme)
            // WebKit's phishing and malware warnings (Safari's Safe Browsing).
            configuration.preferences.isFraudulentWebsiteWarningEnabled = true
            Self.enablePictureInPicture(configuration.preferences)
            Self.enableInspection(configuration.preferences)
            if #available(macOS 15.4, *), !hasExtensionConfiguration,
               let controller = extensionController as? WKWebExtensionController {
                configuration.webExtensionController = controller
            }
            configure(configuration)
            configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        }
        let controller = configuration.userContentController
        registerHandlers(controller, for: tab.id)
        let view = BrowserWebView(frame: .zero, configuration: configuration)
        // WebKit generates the base identity and inherits the opener's suffix
        // in popup configurations. Do not overwrite a supplied configuration.
        view.onOpenWindowLink = { [weak self, weak view] url in
            guard let self, let view else { return }
            _ = self.openContextLinkInWindow(url, in: view)
        }
        view.onOpenBackgroundLink = { [weak self, weak view] url in
            guard let self, let view else { return }
            _ = self.openContextLink(url, in: view, background: true)
        }
        view.onInteractionEnded = { [weak self] in self?.scheduleRetention() }
        view.extensionMenuItems = { [weak self, weak view] in
            guard let self, let view, let id = self.tabID(for: view) else { return [] }
            return self.extensionMenuItems?(id) ?? []
        }
        view.extensionCommand = { [weak self] event in self?.extensionCommand?(event) ?? false }
        view.searchEngineName = { [weak self] in self?.searchEngineName() ?? SearchEngine.google.name }
        view.pageTranslationTitle = { [weak self, weak view] in
            guard let self, let view, let id = self.tabID(for: view) else { return nil }
            return self.translationMenuTitle?(id)
        }
        view.onContextAction = { [weak self, weak view] action in
            guard let self, let view else { return }
            self.performContextAction(action, in: view)
        }
        view.allowsBackForwardNavigationGestures = true
        // Enables WebKit's native pinch and two-finger smart magnification.
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        let page = BrowserPage(view: view, url: tab.currentURL)
        page.extensionOrigin = extensionOrigin
        page.hasExtensionConfiguration = hasExtensionConfiguration
        if muteChoices.contains(tab.id) { page.isMuted = true; page.muteRevision = 1 }
        Self.enableInspection(view)
        if let zoom = zoomChoices[tab.id] {
            page.zoom = zoom
            view.pageZoom = zoom
        }
        pages[tab.id] = page
        identities[ObjectIdentifier(view)] = tab.id
        transition(tab.id, .allocate)
        creationCount += 1
        retentionPolicy.recordUse(of: tab.id)
        scheduleRetention()
        // A queued refresh must still belong to this exact page, not a later
        // replacement reusing the same durable tab identity.
        let gate = RefreshGate()
        let changed: @Sendable () -> Void = { [weak self, weak page] in
            gate.schedule { [weak self, weak page] in
                guard let self, let page, self.pages[tab.id] === page else { return }
                self.refresh(tab.id)
            }
        }
        page.observations = [
            view.observe(\.title) { _, _ in changed() },
            view.observe(\.url) { _, _ in changed() },
            view.observe(\.isLoading) { _, _ in changed() },
            view.observe(\.estimatedProgress) { _, _ in changed() },
            view.observe(\.canGoBack) { _, _ in changed() },
            view.observe(\.canGoForward) { _, _ in changed() },
            view.observe(\.cameraCaptureState) { _, _ in changed() },
            view.observe(\.microphoneCaptureState) { _, _ in changed() },
            view.observe(\.hasOnlySecureContent) { _, _ in changed() },
            view.observe(\.serverTrust) { _, _ in changed() },
            view.observe(\.fullscreenState) { _, _ in changed() }
        ]
        return page
    }

    private func registerHandlers(_ controller: WKUserContentController, for id: UUID) {
        let identity = ObjectIdentifier(controller)
        if controllerOwners[identity] != nil {
            controllerOwners[identity]?.insert(id)
            return
        }
        controllerOwners[identity] = [id]
        let mediaObserver = MediaActivityObserver()
        mediaObserver.owner = self
        controller.removeScriptMessageHandler(forName: MediaActivityObserver.name, contentWorld: .defaultClient)
        controller.addScriptMessageHandler(mediaObserver, contentWorld: .defaultClient, name: MediaActivityObserver.name)
        if !controller.userScripts.contains(where: { $0.source == MediaActivityObserver.script }) {
            controller.addUserScript(WKUserScript(source: MediaActivityObserver.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        let menuObserver = PageContextMenuObserver()
        menuObserver.owner = self
        controller.removeScriptMessageHandler(forName: PageContextMenuObserver.name, contentWorld: PageContextMenuObserver.world)
        controller.add(menuObserver, contentWorld: PageContextMenuObserver.world, name: PageContextMenuObserver.name)
        if !controller.userScripts.contains(where: { $0.source == PageContextMenuObserver.script }) {
            controller.addUserScript(WKUserScript(source: PageContextMenuObserver.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PageContextMenuObserver.world))
        }
        let hoverObserver = LinkHoverObserver()
        hoverObserver.owner = self
        controller.removeScriptMessageHandler(forName: LinkHoverObserver.name, contentWorld: LinkHoverObserver.world)
        controller.add(hoverObserver, contentWorld: LinkHoverObserver.world, name: LinkHoverObserver.name)
        if !controller.userScripts.contains(where: { $0.source == LinkHoverObserver.script }) {
            controller.addUserScript(WKUserScript(source: LinkHoverObserver.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: LinkHoverObserver.world))
        }
        let passwordObserver = PasswordFormObserver()
        passwordObserver.owner = self
        controller.removeScriptMessageHandler(forName: PasswordFormObserver.name, contentWorld: PasswordFormObserver.world)
        controller.add(passwordObserver, contentWorld: PasswordFormObserver.world, name: PasswordFormObserver.name)
        if !controller.userScripts.contains(where: { $0.source == PasswordFormObserver.script }) {
            controller.addUserScript(WKUserScript(source: PasswordFormObserver.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PasswordFormObserver.world))
        }
        let interactionObserver = PageInteractionObserver()
        interactionObserver.owner = self
        controller.removeScriptMessageHandler(forName: PageInteractionObserver.name, contentWorld: .defaultClient)
        controller.add(interactionObserver, contentWorld: .defaultClient, name: PageInteractionObserver.name)
        if !controller.userScripts.contains(where: { $0.source == PageInteractionObserver.script }) {
            controller.addUserScript(WKUserScript(source: PageInteractionObserver.script,
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
    }

    private func unregisterHandlers(_ controller: WKUserContentController, for id: UUID) {
        let identity = ObjectIdentifier(controller)
        controllerOwners[identity]?.remove(id)
        // Opener/popups can share a content controller. Closing one must not
        // detach bridges still owned by another live page.
        guard controllerOwners[identity]?.isEmpty == true else { return }
        controllerOwners[identity] = nil
        controller.removeScriptMessageHandler(forName: MediaActivityObserver.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: PageContextMenuObserver.name, contentWorld: PageContextMenuObserver.world)
        controller.removeScriptMessageHandler(forName: PageInteractionObserver.name, contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: LinkHoverObserver.name, contentWorld: LinkHoverObserver.world)
        controller.removeScriptMessageHandler(forName: PasswordFormObserver.name, contentWorld: PasswordFormObserver.world)
    }

    func beginLoading(_ id: UUID) {
        guard let page = pages[id] else { return }
        page.failure = nil
        page.certificateFailure = nil
        page.navigationNotice = nil
        page.policyCancellations.removeAll()
        page.activeNavigation = nil
        page.isLoading = true
        page.progress = 0
        page.awaitsNavigationCommit = true
        page.navigationGeneration = UUID()
        snapshots.invalidate(tabID: id)
        retentionPolicy.recordUse(of: id)
        transition(id, .startLoading)
    }

    public func load(_ url: URL, in tab: BrowserTab) {
        // A website and an extension's page never share a view; nor does a
        // page made before its extension loaded.
        if let existing = pages[tab.id], existing.extensionOrigin != Self.extensionOrigin(of: url)
            || (existing.extensionOrigin != nil && !existing.hasExtensionConfiguration) {
            releasePage(tabID: tab.id, preservingSnapshot: true)
        }
        let page = prepare(tab, loading: url)
        cancelRecovery(tab.id)
        page.automaticRecoveryAttempted = false
        page.processTerminated = false
        page.requestedURL = url
        page.earlyRequested = url
        beginLoading(tab.id)
        page.activeNavigation = startNavigation(to: url, in: page.view).map(ObjectIdentifier.init)
    }

    /// Local documents receive read access to the chosen file only, which is
    /// all the sandbox grants for a user-selected or dropped file. One opened
    /// before Early restarted reads through its bookmark, and one that can't be
    /// read says why instead of showing a blank page.
    func startNavigation(to url: URL, in view: WKWebView) -> WKNavigation? {
        guard url.isFileURL else { return view.load(URLRequest(url: url)) }
        guard let localFiles, let id = identities[ObjectIdentifier(view)], let page = pages[id] else {
            return view.loadFileURL(url, allowingReadAccessTo: url)
        }
        releaseLocalFile(of: page)
        switch localFiles.access(url) {
        case .readable(let file):
            page.localFile = url
            return view.loadFileURL(file, allowingReadAccessTo: file)
        case .unavailable:
            page.failure = Self.unavailableFileMessage(url)
            transition(id, .fail)
            refresh(id)
            return nil
        }
    }

    static func unavailableFileMessage(_ url: URL) -> String {
        "“\(url.lastPathComponent)” can’t be opened. It may have been moved or deleted, or it was opened before Early "
            + "kept local files across restarts. Open it again from Finder or with File › Open File…"
    }

    func releaseLocalFile(of page: BrowserPage) {
        guard let file = page.localFile else { return }
        page.localFile = nil
        localFiles?.release(file)
    }

    public func activate(_ tab: BrowserTab) {
        if let page = pages[tab.id] {
            if page.processTerminated { recoverIfNeeded(tab.id) }
            return
        }
        load(tab.currentURL, in: tab)
    }

    public func reload(_ id: UUID) {
        guard let page = pages[id] else { return }
        cancelRecovery(id)
        page.automaticRecoveryAttempted = false
        page.processTerminated = false
        let needsRequest = page.failure != nil || page.navigationNotice != nil || page.awaitsNavigationCommit || page.view.url == nil
        beginLoading(id)
        if needsRequest {
            page.activeNavigation = startNavigation(to: page.requestedURL, in: page.view).map(ObjectIdentifier.init)
        } else { page.activeNavigation = page.view.reload().map(ObjectIdentifier.init) }
    }

    public func stop(_ id: UUID) {
        pages[id]?.view.stopLoading()
        transition(id, .stopLoading)
        refresh(id)
    }
    public func back(_ id: UUID) { navigateHistory(id, forward: false) }
    public func forward(_ id: UUID) { navigateHistory(id, forward: true) }

    /// One entry in a tab's own back or forward list, nearest first.
    public struct HistoryListEntry: Equatable, Identifiable, Sendable {
        /// Steps from the current page: negative is back, positive forward.
        public let offset: Int
        public let title: String
        public let url: URL
        public var id: Int { offset }
    }

    /// The focused page's public WebKit back or forward list, nearest first.
    public func historyList(_ id: UUID, forward: Bool, limit: Int = 15) -> [HistoryListEntry] {
        guard let list = pages[id]?.view.backForwardList else { return [] }
        let items = forward ? list.forwardList : Array(list.backList.reversed())
        return items.prefix(limit).enumerated().map { index, item in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return HistoryListEntry(offset: forward ? index + 1 : -(index + 1),
                                    title: title?.isEmpty == false ? title! : (item.url.host ?? item.url.absoluteString),
                                    url: item.url)
        }
    }

    /// Jumps straight to an entry of that list, like repeated Back or Forward.
    @discardableResult
    public func goToHistory(_ id: UUID, offset: Int) -> Bool {
        guard offset != 0, let page = pages[id], let item = page.view.backForwardList.item(at: offset) else { return false }
        navigateHistory(id) { $0.go(to: item) }
        return true
    }

    private func navigateHistory(_ id: UUID, forward: Bool) {
        guard let page = pages[id], forward ? page.view.canGoForward : page.view.canGoBack else { return }
        navigateHistory(id) { forward ? $0.goForward() : $0.goBack() }
    }

    private func navigateHistory(_ id: UUID, using move: (WKWebView) -> WKNavigation?) {
        guard let page = pages[id] else { return }
        cancelRecovery(id)
        page.automaticRecoveryAttempted = false
        page.processTerminated = false
        beginLoading(id)
        let navigation = move(page.view)
        page.activeNavigation = navigation.map(ObjectIdentifier.init)
        if navigation == nil {
            transition(id, .stopLoading)
            refresh(id)
        }
    }

    /// Temporary, page-owned HTML audio/video muting. It survives navigation
    /// in this live tab, but is deliberately not a persisted site preference.
    @discardableResult
    public func setMuted(_ muted: Bool, for id: UUID) -> Bool {
        guard let page = pages[id] else { return false }
        guard page.isMuted != muted else { return true }
        page.isMuted = muted
        if muted { muteChoices.insert(id) } else { muteChoices.remove(id) }
        page.muteRevision += 1
        let script = "globalThis.__earlyMediaControl?.applyState({muted:\(muted),revision:\(page.muteRevision)})"
        // Each document registers its own frame, including cross-origin embeds.
        // Newly loaded documents receive the latest state in their bridge reply.
        page.view.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
        for frame in page.mediaFrames.values where !frame.isMainFrame {
            page.view.evaluateJavaScript(script, in: frame, in: .defaultClient) { _ in }
        }
        return true
    }

    /// Explicit close/delete/shutdown always release. Policy eviction uses the
    /// same cleanup while retaining a bounded stale thumbnail for the switcher.
    public func discard(tabID: UUID) {
        navigationDiagnostics.removeAll { $0.tabID == tabID }
        releasePage(tabID: tabID, preservingSnapshot: false)
        retentionPolicy.forget(tabID)
        muteChoices.remove(tabID)
        zoomChoices[tabID] = nil
    }

    private func releasePage(tabID: UUID, preservingSnapshot: Bool) {
        cancelRecovery(tabID)
        hideReader(tabID)
        if preservingSnapshot { snapshots.cancelCapture(tabID: tabID) }
        else { snapshots.invalidate(tabID: tabID) }
        protections[tabID] = nil
        if let page = pages[tabID] { releaseLocalFile(of: page) }
        if focusedPasswordField?.tabID == tabID { hidePasswordSuggestions() }
        if lifecycles[tabID] != nil { transition(tabID, .discard) }
        guard let page = pages[tabID] else { return }
        // Removing a view/owner and stopping resource loads does not stop its
        // media. An outgoing SwiftUI transition can still retain the document.
        // Native suspension covers HTML media, embedded frames and Web Audio,
        // and blocks stale page scripts from restarting playback after close.
        // Discarded views are never reused; a reopened tab gets a fresh view.
        page.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        identities.removeValue(forKey: ObjectIdentifier(page.view))
        cancelDialog(tabID)
        cancelDocumentPanel(tabID)
        pages.removeValue(forKey: tabID)
        automaticPictureInPictureTabs[tabID] = nil
        unregisterHandlers(page.view.configuration.userContentController, for: tabID)
        page.mediaFrames.removeAll()
        page.playingFrames.removeAll()
        page.isPlayingMedia = false
        page.isLoading = false
        if let view = page.view as? BrowserWebView {
            view.cancelLinkMenu()
            view.onOpenWindowLink = nil
            view.onOpenBackgroundLink = nil
            view.onContextAction = nil
            view.onInteractionEnded = nil
            view.extensionMenuItems = nil
            view.extensionCommand = nil
        }
        page.observations.forEach { $0.invalidate() }
        page.observations.removeAll()
        page.view.stopLoading()
        page.view.navigationDelegate = nil
        page.view.uiDelegate = nil
        if page.view.fullscreenState != .notInFullscreen {
            let view = page.view
            view.closeAllMediaPresentations { view.removeFromSuperview() }
        } else {
            page.view.removeFromSuperview()
        }
    }

    public func discardAll() {
        hidePasswordSuggestions()
        retentionTask?.cancel()
        retentionTask = nil
        for id in Array(pages.keys) { discard(tabID: id) }
        _ = setPresentation(visibleTabIDs: [], focusedTabID: nil)
        retentionTask?.cancel()
        retentionTask = nil
        snapshots.clear()
        navigationDiagnostics.removeAll()
        protections.removeAll()
        muteChoices.removeAll()
    }

    func contextLinkURL(href: String, in view: WKWebView) -> URL? {
        guard identities[ObjectIdentifier(view)] != nil, href.utf8.count <= 16384,
              let url = URL(string: href), (try? input.validate(url)) != nil,
              Self.extensionOrigin(of: url) == nil,
              !url.isFileURL || view.url?.isFileURL == true else { return nil }
        return url
    }

    func showContextMenu(link href: String?, image src: String?, selection: String?, in view: BrowserWebView) {
        guard view.window != nil, tabID(for: view) != nil else { return }
        var target = BrowserWebView.ContextTarget()
        target.link = href.flatMap { contextLinkURL(href: $0, in: view) }
        target.image = src.flatMap { contextImageURL($0) }
        let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { target.selection = String(text.prefix(4096)) }
        view.showContextMenu(for: target)
    }

    /// Images can be opened, saved or copied only through the page's profile.
    func contextImageURL(_ src: String) -> URL? {
        guard src.utf8.count <= 16384, let url = URL(string: src), isDownloadable(url) else { return nil }
        return url
    }

    @discardableResult
    func openContextLinkInWindow(_ url: URL, in view: WKWebView) -> Bool {
        guard contextLinkURL(href: url.absoluteString, in: view) != nil,
              let onOpenWindowLink else { return false }
        onOpenWindowLink(url)
        return true
    }

    @discardableResult
    func openContextLink(_ url: URL, in view: WKWebView, background: Bool) -> Bool {
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id],
              contextLinkURL(href: url.absoluteString, in: view) != nil else { return false }
        if background {
            guard let onOpenBackgroundLink else { return false }
            onOpenBackgroundLink(url)
        } else {
            page.requestedURL = url
            beginLoading(id)
            page.activeNavigation = startNavigation(to: url, in: view).map(ObjectIdentifier.init)
        }
        return true
    }

    @discardableResult
    func updateMediaActivity(in view: WKWebView, token: String, playing: Bool,
                             frame: WKFrameInfo? = nil, removed: Bool = false) -> [String: Any]? {
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id] else { return nil }
        if removed {
            page.mediaFrames.removeValue(forKey: token)
            page.playingFrames.remove(token)
        } else {
            if let frame { page.mediaFrames[token] = frame }
            if playing { page.playingFrames.insert(token) }
            else { page.playingFrames.remove(token) }
        }
        page.isPlayingMedia = !page.playingFrames.isEmpty
        scheduleRetention()
        return ["muted": page.isMuted, "revision": page.muteRevision]
    }

    func updatePageInteraction(in view: WKWebView, token: String, removed: Bool) {
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id] else { return }
        if removed { page.editedFrames.remove(token) }
        else {
            // A bounded set still conservatively protects the page if a site
            // manufactures more frame identities than expected.
            if page.editedFrames.count < 128 { page.editedFrames.insert(token) }
            snapshots.invalidate(tabID: id)
        }
        page.hasUnsavedInput = !page.editedFrames.isEmpty
        scheduleRetention()
    }

    func refresh(_ id: UUID) {
        guard let page = pages[id] else { return }
        let view = page.view
        page.isLoading = view.isLoading
        page.progress = view.estimatedProgress
        page.canGoBack = view.canGoBack
        page.canGoForward = view.canGoForward
        let fullscreen = view.fullscreenState != .notInFullscreen
        if page.isFullscreen != fullscreen { page.isFullscreen = fullscreen }
        if page.cameraCapture != view.cameraCaptureState { page.cameraCapture = view.cameraCaptureState }
        if page.microphoneCapture != view.microphoneCaptureState { page.microphoneCapture = view.microphoneCaptureState }
        updateSecurity(page)
        if view.isLoading && page.failure == nil { transition(id, .startLoading) }
        else if !view.isLoading { transition(id, .stopLoading) }
        let url = view.url.flatMap { try? input.validate($0) }
        let successfulDocument = !view.isLoading && !page.awaitsNavigationCommit
            && page.failure == nil && !page.processTerminated
        if successfulDocument, let url { page.requestedURL = url }
        if successfulDocument, let url, let previous = page.reportedURL, previous != url {
            // History API route changes have no provisional navigation callback.
            // Fence captures from the previous route just as a full load does.
            page.navigationGeneration = UUID()
            snapshots.invalidate(tabID: id)
            // Reader stays open: scripts may rewrite the address while reading.
            if !page.isReaderShown { checkReaderAvailability(id) }
        }
        let title = view.title
        if url != page.reportedURL || title != page.reportedTitle {
            page.reportedURL = url
            page.reportedTitle = title
            onMetadata?(id, url, title)
        }
        scheduleRetention()
    }
}
