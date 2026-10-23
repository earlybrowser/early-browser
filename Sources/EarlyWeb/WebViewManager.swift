// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import Observation
import WebKit

@MainActor @Observable
public final class BrowserPage {
    public let view: WKWebView
    /// Unique per live page; a reopened tab's new page never shares it (unlike
    /// an object address, which a new page can reuse).
    public let instanceID = UUID()
    public var isLoading = false
    public var isPlayingMedia = false
    public fileprivate(set) var isMuted = false
    var playingFrames: Set<String> = []
    var mediaFrames: [String: WKFrameInfo] = [:]
    fileprivate var muteRevision = 0
    public var progress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    public var failure: String?
    public fileprivate(set) var navigationNotice: String?
    public var hasDialog = false
    public fileprivate(set) var hasUnsavedInput = false
    public fileprivate(set) var processTerminated = false
    fileprivate var editedFrames: Set<String> = []
    fileprivate var automaticRecoveryAttempted = false
    fileprivate var awaitsNavigationCommit = false
    public var requestedURL: URL
    /// This tab's page zoom; 1 is actual size. Not remembered per site.
    public internal(set) var zoom = 1.0
    /// The find bar's state; nil while it is closed.
    public internal(set) var find: PageFindState?
    var findRevision = 0
    /// The link under the pointer, for the pane's address preview.
    public internal(set) var hoveredLink: LinkHover?
    public internal(set) var isFullscreen = false
    /// Readability judged this document an article.
    public internal(set) var isReaderAvailable = false
    public internal(set) var isPreparingReader = false
    public internal(set) var isReaderShown = false
    public internal(set) var readerArticle: ReaderArticle?
    /// The page's language (BCP 47), detected from its text after loading.
    public internal(set) var language: String?
    public internal(set) var translation = PageTranslationPhase.original
    /// The connection's trust, from WebKit's public secure-content state.
    public internal(set) var security = PageSecurity.none
    /// The certificate behind `security`, for the certificate panel.
    public internal(set) var serverTrust: SecTrust?
    /// A navigation refused for its certificate, until the next one starts.
    var certificateFailure: CertificateFailure?
    public internal(set) var cameraCapture = WKMediaCaptureState.none
    public internal(set) var microphoneCapture = WKMediaCaptureState.none
    /// The committed main document's MIME type, e.g. a viewed PDF.
    public fileprivate(set) var documentMIMEType: String?
    fileprivate var pendingDocumentMIMEType: String?
    fileprivate var observations: [NSKeyValueObservation] = []
    fileprivate var reportedURL: URL?
    var reportedTitle: String?
    var navigationGeneration = UUID()
    fileprivate var activeNavigation: ObjectIdentifier?
    fileprivate var policyCancellations: [NavigationPolicyCancellation] = []
    fileprivate init(view: WKWebView, url: URL) { self.view = view; requestedURL = url }

    struct CertificateFailure {
        let url: URL?
        let trust: SecTrust?
    }
}

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
    private var protections: [UUID: [UUID: Protection]] = [:]
    private var muteChoices: Set<UUID> = []
    /// Zoom belongs to the tab, so it survives background discard and recovery.
    var zoomChoices: [UUID: Double] = [:]
    /// Tabs whose page Safari's Web Inspector may attach to; none by default.
    public internal(set) var developerModeTabs: Set<UUID> = []
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
    /// Whether a tab switched away from keeps its playing video in Picture in Picture.
    public var automaticPictureInPicture: () -> Bool = { false }
    /// Tabs whose video Early is moving, or moved, into Picture in Picture.
    @ObservationIgnored var automaticPictureInPictureTabs: [UUID: AutomaticPictureInPicture] = [:]
    /// Runs a page script and reports whether it returned true; tests observe it.
    @ObservationIgnored var runPageScript: (WKWebView, String, WKFrameInfo?) async -> Bool = { view, script, frame in
        (try? await view.callAsyncJavaScript(script, in: frame, contentWorld: .defaultClient)) as? Bool == true
    }
    let profileID: UUID
    let ephemeral: Bool
    let input: NavigationInput
    private let configure: (WKWebViewConfiguration) -> Void
    private var store: WKWebsiteDataStore?
    private var identities: [ObjectIdentifier: UUID] = [:]
    var dialogs: [UUID: PendingDialog] = [:]
    var documentPanels: [UUID: PendingPanel] = [:]
    private var controllerOwners: [ObjectIdentifier: Set<UUID>] = [:]
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var memoryMonitor: PageMemoryPressureMonitor?
    private var pressure: PageRetentionPolicy.Pressure = .normal
    // Diagnostic work counts do not trigger SwiftUI observation or record URLs.
    struct WorkMetrics {
        var retentionPasses = 0
        var inspectedPages = 0
        var presentationVisits = 0
    }
    @ObservationIgnored private(set) var workMetrics = WorkMetrics()
    @ObservationIgnored public private(set) var navigationDiagnostics: [NavigationDiagnostic] = []

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
        developerModeTabs.formIntersection(open)
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

    private func captureSnapshot(_ id: UUID) {
        guard pressure == .normal, let page = pages[id], !page.isLoading,
              page.failure == nil, !page.hasUnsavedInput, !page.hasDialog,
              page.view.bounds.width > 0, page.view.bounds.height > 0 else { return }
        snapshots.request(tabID: id, navigationID: page.navigationGeneration, view: page.view)
    }

    private func transition(_ id: UUID, _ event: PageLifecycle.Event) {
        var runtime = lifecycle(for: id)
        if runtime.transition(event) { lifecycles[id] = runtime }
    }

    /// Called by accepted navigation/selection, never by SwiftUI rendering.
    @discardableResult
    public func prepare(_ tab: BrowserTab, configuration supplied: WKWebViewConfiguration? = nil) -> BrowserPage {
        precondition(tab.profileID == profileID, "A manager owns exactly one profile")
        if let page = pages[tab.id] { return page }
        let configuration: WKWebViewConfiguration
        if let supplied {
            // WebKit requires the exact supplied configuration for window.open.
            configuration = supplied
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = websiteDataStore
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isElementFullscreenEnabled = true
            Self.enablePictureInPicture(configuration.preferences)
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
        if muteChoices.contains(tab.id) { page.isMuted = true; page.muteRevision = 1 }
        if developerModeTabs.contains(tab.id) { view.isInspectable = true }
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
    }

    private func beginLoading(_ id: UUID) {
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
        let page = prepare(tab)
        cancelRecovery(tab.id)
        page.automaticRecoveryAttempted = false
        page.processTerminated = false
        page.requestedURL = url
        beginLoading(tab.id)
        page.activeNavigation = startNavigation(to: url, in: page.view).map(ObjectIdentifier.init)
    }

    /// Local documents receive read access to the chosen file only, which is
    /// all the sandbox grants for a user-selected or dropped file.
    private func startNavigation(to url: URL, in view: WKWebView) -> WKNavigation? {
        url.isFileURL ? view.loadFileURL(url, allowingReadAccessTo: url) : view.load(URLRequest(url: url))
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
        developerModeTabs.remove(tabID)
    }

    private func releasePage(tabID: UUID, preservingSnapshot: Bool) {
        cancelRecovery(tabID)
        hideReader(tabID)
        if preservingSnapshot { snapshots.cancelCapture(tabID: tabID) }
        else { snapshots.invalidate(tabID: tabID) }
        protections[tabID] = nil
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
              (try? input.validate(url)) != nil, !url.isFileURL || view.url?.isFileURL == true else { return false }
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

    private func refresh(_ id: UUID) {
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

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload, isDownloadable(url) {
            if let id = identities[ObjectIdentifier(webView)] {
                // WebKit ends the navigation once it becomes a download; that
                // expected interruption is not a page failure.
                cancelForPolicy(id, url: url, mainFrame: mainFrame, notice: nil)
                recordNavigation(.init(tabID: id, event: "download-action", url: url, isMainFrame: mainFrame))
            }
            decisionHandler(.download)
            return
        }
        if url.isFileURL {
            decideLocalNavigation(to: url, action: action, in: webView, mainFrame: mainFrame, decisionHandler: decisionHandler)
            return
        }
        if (try? input.validate(url)) != nil {
            if openCommandClickedLink(action, in: webView) {
                decisionHandler(.cancel)
                return
            }
            if mainFrame, action.targetFrame != nil,
               let id = identities[ObjectIdentifier(webView)] {
                pages[id]?.requestedURL = url
                if action.navigationType != .other {
                    cancelRecovery(id)
                    pages[id]?.automaticRecoveryAttempted = false
                    pages[id]?.processTerminated = false
                }
            }
            decisionHandler(.allow)
        } else if !mainFrame, ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if let id = identities[ObjectIdentifier(webView)] {
                cancelForPolicy(id, url: url, mainFrame: mainFrame,
                    notice: mainFrame ? "This link uses an unsupported address type (\(url.scheme ?? "unknown"))." : nil)
            }
        }
    }

    /// Web addresses are validated; data/blob documents are page-local files.
    func isDownloadable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "data", "blob": true
        case "http", "https": (try? input.validate(url)) != nil
        default: false
        }
    }

    /// Local documents load only from Early's own requests (Open File, drops,
    /// restoration, reload), from another local page, or through history. A
    /// web page can never open a local file.
    private func decideLocalNavigation(to url: URL, action: WKNavigationAction, in webView: WKWebView, mainFrame: Bool,
                                       decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard (try? input.validate(url)) != nil, let id = identities[ObjectIdentifier(webView)], let page = pages[id] else {
            decisionHandler(.cancel)
            return
        }
        let fromLocalPage = webView.url?.isFileURL == true
        if page.requestedURL == url || fromLocalPage || action.navigationType == .backForward || action.navigationType == .reload {
            if mainFrame { page.requestedURL = url }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        cancelForPolicy(id, url: url, mainFrame: mainFrame, notice: nil)
        // A file dropped on a page that does not accept it opens as a new tab,
        // leaving a pinned or saved page in place.
        if mainFrame, action.navigationType == .other { onOpenFiles?([url]) }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponsePolicy(for: webView, response: response.response,
            canShowMIMEType: response.canShowMIMEType, isMainFrame: response.isForMainFrame))
    }

    /// Same path for the delegate and deterministic response fixtures. Embedded
    /// responses cannot produce a top-level download warning or page failure.
    func navigationResponsePolicy(for view: WKWebView, response: URLResponse,
                                  canShowMIMEType: Bool, isMainFrame: Bool) -> WKNavigationResponsePolicy {
        guard let id = identities[ObjectIdentifier(view)], pages[id] != nil else { return .cancel }
        let disposition = NavigationResponseDisposition.classify(response, canShowMIMEType: canShowMIMEType, isMainFrame: isMainFrame)
        recordNavigation(.init(tabID: id, event: "response-\(disposition.rawValue)", url: response.url,
            status: (response as? HTTPURLResponse)?.statusCode, mimeType: response.mimeType, isMainFrame: isMainFrame))
        guard disposition != .allow else {
            if isMainFrame { pages[id]?.pendingDocumentMIMEType = response.mimeType?.lowercased() }
            return .allow
        }
        // A download ends this navigation with WebKit's expected interruption;
        // the current page stays as it was, without a notice or failure.
        cancelForPolicy(id, url: response.url, mainFrame: isMainFrame, notice: nil)
        if isMainFrame { keepCurrentDocument(id) }
        return disposition == .download && response.url.map(isDownloadable) == true ? .download : .cancel
    }

    /// Reload must reload the page still on screen, not repeat a download.
    private func keepCurrentDocument(_ id: UUID) {
        guard let page = pages[id] else { return }
        page.pendingDocumentMIMEType = nil
        guard let current = page.view.url.flatMap({ try? input.validate($0) }) else { return }
        page.requestedURL = current
        page.awaitsNavigationCommit = false
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adoptDownload(download, from: webView)
        closeBlankPageAfterDownload(webView)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adoptDownload(download, from: webView)
        closeBlankPageAfterDownload(webView)
    }

    /// A tab opened only for a download (a target-blank file link, or an address
    /// that turned out to be a file) has nothing to show; close it as other
    /// browsers do. The download continues.
    private func closeBlankPageAfterDownload(_ view: WKWebView) {
        guard let id = tabID(for: view), view.url == nil, !view.canGoBack else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.pages[id]?.view === view, view.url == nil else { return }
            self.onClose?(id)
        }
    }

    /// Downloads outlive their page; while active they protect it from
    /// background discard, because a blob/data source belongs to its document.
    @discardableResult
    func adoptDownload(_ download: WKDownload, from view: WKWebView?, destination: URL? = nil, listed: Bool = true,
                       settled: ((DownloadItem) -> Void)? = nil) -> DownloadItem {
        let id = view.flatMap { identities[ObjectIdentifier($0)] }
        let origin = id.flatMap { pages[$0]?.view.url }
        let item = downloads.adopt(download, source: download.originalRequest?.url, origin: origin,
                                   destination: destination, listed: listed)
        if let id, let token = protect(tabID: id, reason: .download) {
            item.onSettled.append { [weak self] _ in self?.releaseProtection(tabID: id, token: token) }
        }
        if let settled { item.onSettled.append(settled) }
        if listed { onDownloadStarted?(item) }
        return item
    }

    /// Download Linked File, Save Image As and saving a viewed PDF.
    @discardableResult
    public func startDownload(_ url: URL, from tabID: UUID, to destination: URL? = nil, listed: Bool = true,
                              settled: ((DownloadItem) -> Void)? = nil) -> Bool {
        guard let page = pages[tabID], isDownloadable(url) else { return false }
        // Adopt inside WebKit's callback. WebKit can ask for a destination right
        // after it, and a delegate set from an awaited continuation may be too
        // late: the download would then be dropped while it shows "Starting…".
        page.view.startDownload(using: URLRequest(url: url)) { [weak self, weak view = page.view] download in
            guard let self else { download.cancel { _ in }; return }
            self.adoptDownload(download, from: view, destination: destination, listed: listed, settled: settled)
        }
        return true
    }

    func hasProtection(tabID: UUID, reason: Protection) -> Bool {
        protections[tabID]?.values.contains(reason) == true
    }

    private func cancelForPolicy(_ id: UUID, url: URL?, mainFrame: Bool, notice: String?) {
        guard let page = pages[id] else { return }
        page.policyCancellations.append(.init(generation: page.navigationGeneration, url: url, isMainFrame: mainFrame))
        if page.policyCancellations.count > 8 { page.policyCancellations.removeFirst() }
        if mainFrame { page.navigationNotice = notice }
    }

    public func dismissNavigationNotice(for id: UUID) { pages[id]?.navigationNotice = nil }

    private func recordNavigation(_ event: NavigationDiagnostic) {
        navigationDiagnostics.append(event)
        if navigationDiagnostics.count > 24 { navigationDiagnostics.removeFirst(navigationDiagnostics.count - 24) }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        beginLoading(id)
        pages[id]?.activeNavigation = navigation.map(ObjectIdentifier.init)
        refresh(id)
    }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        pages[id]?.playingFrames.removeAll()
        pages[id]?.mediaFrames.removeAll()
        pages[id]?.isPlayingMedia = false
        pages[id]?.editedFrames.removeAll()
        pages[id]?.hasUnsavedInput = false
        pages[id]?.awaitsNavigationCommit = false
        pages[id]?.policyCancellations.removeAll()
        pages[id]?.navigationNotice = nil
        pages[id]?.documentMIMEType = pages[id]?.pendingDocumentMIMEType
        pages[id]?.pendingDocumentMIMEType = nil
        resetFindForNewDocument(id)
        pages[id]?.hoveredLink = nil
        // Reader shows one document; a new one returns to the page.
        hideReader(id)
        pages[id]?.isReaderAvailable = false
        resetTranslationForNewDocument(id)
        if let url = webView.url.flatMap({ try? input.validate($0) }) { pages[id]?.requestedURL = url }
    }
    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        recordNavigation(.init(tabID: id, event: "redirect", url: webView.url, isMainFrame: true))
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)], let page = pages[id] else { return }
        page.navigationNotice = nil
        page.policyCancellations.removeAll()
        transition(id, .finishLoading)
        refresh(id)
        captureSnapshot(id)
        scheduleRetention()
        refreshFindAfterLoad(id)
        checkReaderAvailability(id)
        detectPageLanguage(id)
        guard let url = webView.url else { return }
        let generation = page.navigationGeneration
        // Read only the loaded document, in an isolated JS world. No injected
        // observers, external discovery service, or off-screen page loads.
        webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('link[rel]'))
                .filter(link => link.rel.toLowerCase().split(/\\s+/).includes('icon'))
                .slice(0, 8).map(link => link.href)
            """, in: nil, in: .defaultClient) { [weak self, weak page] result in
                guard let self, let page, self.pages[id] === page,
                      page.navigationGeneration == generation, page.view.url == url else { return }
                let links = (try? result.get()) as? [String] ?? []
                self.favicons.request(url, discovered: links)
            }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error)
    }
    private func failed(_ view: WKWebView, navigation: WKNavigation?, _ error: Error) {
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id] else { return }
        let nsError = error as NSError
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let navigation, let active = page.activeNavigation, active != ObjectIdentifier(navigation) {
            recordNavigation(.init(tabID: id, event: "stale-navigation-error", url: failingURL, isMainFrame: true, error: nsError))
            return
        }
        // WebKit reports intentional policy cancellation with its legacy error
        // domain/code (WebKitErrors.h). Suppress only our matching decision, not
        // every policy error, and never match an unrelated NSError by code alone.
        let interruption = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        let match = interruption ? page.policyCancellations.firstIndex { cancellation in
            cancellation.generation == page.navigationGeneration
                && (failingURL == nil ? cancellation.isMainFrame : cancellation.url == failingURL)
        } : nil
        if let match {
            let cancelled = page.policyCancellations.remove(at: match)
            recordNavigation(.init(tabID: id, event: "expected-policy-cancellation", url: failingURL ?? cancelled.url,
                isMainFrame: cancelled.isMainFrame, error: nsError))
            if cancelled.isMainFrame { refresh(id) }
            return
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            recordNavigation(.init(tabID: id, event: "cancelled", url: failingURL, isMainFrame: true, error: nsError))
            refresh(id)
            return
        }
        recordNavigation(.init(tabID: id, event: "failure", url: failingURL ?? page.requestedURL, isMainFrame: true, error: nsError))
        if Self.isCertificateError(nsError) {
            page.certificateFailure = .init(url: failingURL ?? page.requestedURL, trust: Self.peerTrust(nsError))
        }
        page.failure = error.localizedDescription
        transition(id, .fail)
        refresh(id)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = identities[ObjectIdentifier(webView)], let page = pages[id] else { return }
        cancelRecovery(id)
        snapshots.invalidate(tabID: id)
        page.navigationGeneration = UUID()
        page.failure = "The web content process stopped. Reload to reopen this page."
        page.processTerminated = true
        page.isLoading = false
        page.isPlayingMedia = false
        page.playingFrames.removeAll()
        page.mediaFrames.removeAll()
        cancelDialog(id)
        transition(id, .fail)
        // Background failures do not generate network requests. Selection can
        // recover them later. Only one automatic retry is allowed until the
        // user explicitly navigates/reloads, including repeated crash loops.
        if visibleTabIDs.contains(id) { recoverIfNeeded(id) }
        scheduleRetention()
    }

    private func cancelRecovery(_ id: UUID) {
        recoveryTasks.removeValue(forKey: id)?.cancel()
    }

    private func recoverIfNeeded(_ id: UUID) {
        guard let page = pages[id], page.processTerminated, !page.automaticRecoveryAttempted,
              !page.hasUnsavedInput, recoveryTasks[id] == nil else { return }
        page.automaticRecoveryAttempted = true
        let generation = page.navigationGeneration
        recoveryTasks[id] = Task { @MainActor [weak self, weak page] in
            await Task.yield()
            guard !Task.isCancelled, let self, let page, self.pages[id] === page,
                  page.navigationGeneration == generation else { return }
            self.recoveryTasks[id] = nil
            guard self.visibleTabIDs.contains(id), page.processTerminated else {
                page.automaticRecoveryAttempted = false
                return
            }
            page.processTerminated = false
            self.beginLoading(id)
            // Reload the last validated address as a GET; never replay POST
            // bodies, dialogs, or claim that dead form/JavaScript state survived.
            page.activeNavigation = startNavigation(to: page.requestedURL, in: page.view).map(ObjectIdentifier.init)
        }
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Never accept invalid certificates or manufacture credentials.
        completionHandler(.performDefaultHandling, nil)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard identities[ObjectIdentifier(webView)] != nil,
              let url = action.request.url, (try? input.validate(url)) != nil,
              !url.isFileURL || webView.url?.isFileURL == true else { return nil }
        // Target-blank links may arrive through the new-window delegate first.
        // Returning nil consumes the gesture without creating a second tab.
        if openCommandClickedLink(action, in: webView) { return nil }
        return onNewWindow?(url, configuration)
    }

    private func openCommandClickedLink(_ action: WKNavigationAction, in view: WKWebView) -> Bool {
        guard Self.isCommandClick(navigationType: action.navigationType, buttonNumber: action.buttonNumber,
                                  modifiers: action.modifierFlags),
              let url = action.request.url else { return false }
        return openContextLink(url, in: view, background: true)
    }

    static func isCommandClick(navigationType: WKNavigationType, buttonNumber: Int,
                               modifiers: NSEvent.ModifierFlags) -> Bool {
        // WKNavigationAction uses WebKit's button mask: left = 1, none = 0.
        // It is not NSEvent's zero-based buttonNumber (or DOM MouseEvent.button).
        navigationType == .linkActivated && buttonNumber == 1 && modifiers.contains(.command)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if let id = identities[ObjectIdentifier(webView)] { onClose?(id) }
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        showDialog(webView, frame: frame, message: message, kind: .alert) { _, _ in completionHandler() }
    }
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        showDialog(webView, frame: frame, message: message, kind: .confirm) { accepted, _ in completionHandler(accepted) }
    }
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor (String?) -> Void) {
        showDialog(webView, frame: frame, message: prompt, kind: .prompt(defaultText ?? "")) {
            accepted, value in completionHandler(accepted ? value : nil)
        }
    }

    private enum DialogKind { case alert, confirm, prompt(String) }
    struct PendingDialog {
        let alert: NSAlert
        let parent: NSWindow
        /// The button chosen, or nil when the dialog was dismissed without one.
        let complete: (NSApplication.ModalResponse?, String?) -> Void
        let field: NSTextField?
    }
    private func showDialog(_ view: WKWebView, frame: WKFrameInfo, message: String, kind: DialogKind,
                            complete: @escaping (Bool, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(frame.request.url?.host ?? "Website") says"
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        var field: NSTextField?
        switch kind {
        case .alert: break
        case .confirm: alert.addButton(withTitle: "Cancel")
        case .prompt(let value):
            alert.addButton(withTitle: "Cancel")
            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            inputField.stringValue = String(value.prefix(4096))
            inputField.setAccessibilityLabel("Website prompt response")
            alert.accessoryView = inputField
            alert.window.initialFirstResponder = inputField
            field = inputField
        }
        presentAlert(alert, field: field, in: view) { response, value in complete(response == .alertFirstButtonReturn, value) }
    }

    /// One sheet per window: website dialogs and permission prompts alike.
    func presentAlert(_ alert: NSAlert, field: NSTextField? = nil, in view: WKWebView,
                      complete: @escaping (NSApplication.ModalResponse?, String?) -> Void) {
        guard let id = identities[ObjectIdentifier(view)], let window = view.window,
              window.attachedSheet == nil else { complete(nil, nil); return }
        dialogs[id] = PendingDialog(alert: alert, parent: window, complete: complete, field: field)
        // JavaScript is suspended until this sheet completes. Hide the blocked
        // page's accessibility subtree while the native modal owns interaction;
        // traversing it can otherwise wait on the suspended WebKit process.
        view.setAccessibilityHidden(true)
        pages[id]?.hasDialog = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let pending = self?.dialogs.removeValue(forKey: id) else { return }
            self?.pages[id]?.view.setAccessibilityHidden(false)
            self?.pages[id]?.hasDialog = false
            pending.complete(response, pending.field?.stringValue)
            self?.scheduleRetention()
        }
    }
    private func cancelDialog(_ id: UUID) {
        guard let pending = dialogs.removeValue(forKey: id) else { return }
        pages[id]?.view.setAccessibilityHidden(false)
        pages[id]?.hasDialog = false
        pending.parent.endSheet(pending.alert.window)
        pending.complete(nil, nil)
    }
}

/// The lock protects only this one flag; no UI work runs under the lock.
final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard !queued else { lock.unlock(); return }
        queued = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            queued = false
            lock.unlock()
            work()
        }
    }
}
