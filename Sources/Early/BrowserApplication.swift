// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import Observation
import SwiftUI
import WebKit

/// The application owns the profile catalog and the only session writer.
/// A window and its WebKit manager never change their storage identity.
@MainActor @Observable
final class EarlyAppDelegate: NSObject, NSApplicationDelegate {
    private struct WindowEntry { let id: UUID; let model: BrowserWindowModel }
    /// A browser window's native window, as it registered (nil: the primary one).
    private struct NativeWindow { let id: UUID?; weak var window: NSWindow? }
    private struct Loaded {
        let workspace: BrowserWorkspace
        let repository: SessionRepository
        let input: NavigationInput
        let testing: Bool
        let error: String?
    }

    private(set) var model: BrowserWindowModel?
    private(set) var workspace: BrowserWorkspace?
    private(set) var persistence: SessionAutosaver?
    private(set) var storageURL: URL?
    private(set) var profileOperationInProgress = false
    var profileError: String?
    var settingsSection: BrowserSettingsSection = .appearance
    var browserImportPresented = false
    private(set) var browserImportBatches: [BrowserImportBatch] = []
    private(set) var browserImportError: String?
    @ObservationIgnored var presentWindow: ((UUID) -> Void)?
    @ObservationIgnored var presentSettingsWindow: (() -> Void)?
    @ObservationIgnored private var windows: [WindowEntry] = []
    /// Native windows are matched as objects: SwiftUI can rename a window after
    /// Early names it (macOS 26 renamed a second one "browser-AppWindow-2").
    @ObservationIgnored private var nativeWindows: [NativeWindow] = []
    @ObservationIgnored private var loading: Task<Loaded, Never>?
    @ObservationIgnored private var repository: SessionRepository?
    @ObservationIgnored private var preferences: BrowserPreferences?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var input = NavigationInput()
    @ObservationIgnored private var testing = false
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// Profile-owned download lists outlive every tab and window.
    @ObservationIgnored private var downloadStores: [UUID: DownloadStore] = [:]
    /// Each profile's browsing history, beside the session file.
    @ObservationIgnored private var historyStores: [UUID: HistoryStore] = [:]
    /// Each profile's per-site permissions; a private session's stay in memory.
    @ObservationIgnored private var sitePermissionStores: [UUID: SitePermissions] = [:]
    /// Each profile's saved passwords, opened when first needed.
    @ObservationIgnored private var passwordVaults: [UUID: PasswordVault] = [:]
    /// Each profile's bookmarks for local files it opened; a private session's stay in memory.
    @ObservationIgnored private var localFileStores: [UUID: LocalFileBookmarks] = [:]
    /// Settings › Passwords opens only with Touch ID or the Mac's password.
    let passwordsLock = PasswordsLock()
    /// The profile whose passwords Settings shows, and what it searches for.
    var passwordsProfileID: UUID?
    var passwordSearch = ""
    /// Each profile's extensions at work (an `ExtensionHost`, macOS 15.4 and
    /// later), and in private windows opened from it, only those allowed there.
    @ObservationIgnored private var extensionHosts: [UUID: AnyObject] = [:]
    @ObservationIgnored private var privateExtensionHosts: [UUID: AnyObject] = [:]
    @ObservationIgnored private var extensionCatalogs: [UUID: ExtensionCatalog] = [:]
    /// The profile whose extensions Settings shows.
    var extensionsProfileID: UUID?
    /// The profile Settings › Privacy shows.
    var privacyProfileID: UUID?
    /// Whether Early opens web links from other apps. Checked again whenever
    /// Early comes to the front, since it can change in System Settings.
    private(set) var isDefaultBrowser = false
    /// Tests use their own, so nothing changes the Mac's default browser.
    @ObservationIgnored var defaultBrowser: DefaultBrowser?
    /// Early's own updates; nil in tests and UI automation.
    private(set) var updater: SoftwareUpdater?
    /// Links from other apps that arrived before the windows were ready.
    @ObservationIgnored private var pendingLinks: [URL] = []
    /// The most links taken from other apps at once.
    static let externalLinkLimit = 10
    /// Each profile's open pull requests, read while one of its open windows
    /// has a GitHub live folder. Never for private windows.
    @ObservationIgnored private var pullRequestFeeds: [UUID: PullRequestFeed] = [:]
    /// Tests read stand-in pages; UI automation never reaches GitHub.
    @ObservationIgnored var pullRequestReader: PullRequestFeed.Read?
    /// All open private windows share one temporary profile and one website
    /// data store kept only in memory, released with the last private window.
    @ObservationIgnored private(set) var privateProfileID: UUID?
    /// A recently closed window, listed in History › Recently Closed.
    struct ClosedWindow: Identifiable {
        let id = UUID()
        let session: BrowserSession

        /// Its first Today tab's title, and how many more it had.
        var title: String {
            let tabs = session.tabs.filter { $0.isOpen && $0.pinnedURL == nil && !$0.isFavorite }
            let first = tabs.first?.displayTitle ?? "Window"
            return tabs.count > 1 ? "\(first) and \(tabs.count - 1) More" : first
        }
    }

    /// Recently closed ordinary windows with Today tabs, newest last. Never
    /// private windows, and only for this run of the app.
    private(set) var closedWindows: [ClosedWindow] = []
    static let closedWindowLimit = 10
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var applyingWorkspace = false
    @ObservationIgnored private var restoringFocus = false
    @ObservationIgnored private var pendingRestoredWindows: Set<UUID> = []
    @ObservationIgnored private var cleaningWebsiteData = false
    private var primaryWindowIsOpen = false
    /// Whether the window in front shows a page, for ⌘W's title. SwiftUI
    /// doesn't observe the key window, and a menu that read it itself kept
    /// "Close Window" after a new window loaded a page (macOS 26).
    let frontWindowState = FrontWindowState()
    @ObservationIgnored private var frontWindowGeneration = 0

    override init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(frontWindowMayHaveChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func frontWindowMayHaveChanged(_ notification: Notification) { updateFrontWindow() }

    /// Looks at the window in front (the browser window behind a website
    /// dialog), and again whenever its page comes or goes.
    func updateFrontWindow(_ window: NSWindow? = NSApp.keyWindow) {
        frontWindowGeneration &+= 1
        let generation = frontWindowGeneration
        let front = browserModel(for: window.map { $0.sheetParent ?? $0 })
        let showsPage = withObservationTracking { front.map { !$0.showsNoPage } ?? false } onChange: { [weak self, weak window] in
            Task { @MainActor in
                // A newer look, at another window or this one, replaces this one.
                guard let self, self.frontWindowGeneration == generation else { return }
                self.updateFrontWindow(window)
            }
        }
        if frontWindowState.showsPage != showsPage { frontWindowState.showsPage = showsPage }
    }

    var profiles: [BrowserProfile] { workspace?.profiles ?? [] }
    var canOpenWindow: Bool { workspace != nil && presentWindow != nil && !isTerminating && !profileOperationInProgress }
    var canEditProfiles: Bool { workspace != nil && persistence?.isAvailable == true && !profileOperationInProgress && !isTerminating }
    private var visibleModels: [BrowserWindowModel] { (primaryWindowIsOpen ? model.map { [$0] } ?? [] : []) + windows.map(\.model) }

    func windowModel(_ id: UUID?) -> BrowserWindowModel? {
        guard let id else { return model }
        return windows.first { $0.id == id }?.model
    }

    func bootstrap(launchStore: FirstLaunchStore, preferences: BrowserPreferences, defaults: UserDefaults,
                   storageDirectory: URL? = nil, isTesting: Bool = false) async -> [UUID] {
        guard workspace == nil else { return [] }
        if loading == nil {
            loading = Task {
                var suite: String?
                #if DEBUG
                if let value = ProcessInfo.processInfo.environment["EARLY_TEST_DEFAULTS_SUITE"],
                   value.hasPrefix("local.early.tests."),
                   value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) { suite = value }
                #endif
                let testing = suite != nil || isTesting
                let schemes: Set<String> = Set(testing ? ["http", "https", "file", "view-source", "early-test"]
                                                         : ["http", "https", "file", "view-source"])
                let input = NavigationInput(allowedSchemes: schemes.union(NavigationInput.extensionSchemes))
                var directory = storageDirectory ?? URL.applicationSupportDirectory.appending(path: "Early", directoryHint: .isDirectory)
                if storageDirectory == nil, let suite { directory.append(path: "UITests/\(suite)", directoryHint: .isDirectory) }
                let repository = SessionRepository(fileURL: directory.appending(path: "session.sqlite"), input: input)
                do {
                    let saved = try await repository.loadWorkspace() ?? BrowserWorkspace()
                    let imports = BrowserImportJournal(directory: directory.appendingPathComponent("BrowserImports"))
                    _ = try await imports.recover(workspace: saved, historyDirectory: directory.appendingPathComponent("History"))
                    return Loaded(workspace: saved, repository: repository, input: input, testing: testing, error: nil)
                } catch {
                    return Loaded(workspace: BrowserWorkspace(), repository: repository, input: input, testing: testing,
                        error: "The existing session was left untouched. Browsing is temporary until storage is repaired. \(error.localizedDescription)")
                }
            }
        }
        guard let loaded = await loading?.value, !Task.isCancelled, workspace == nil else { return [] }
        loading = nil
        self.preferences = preferences
        self.defaults = defaults
        self.repository = loaded.repository
        self.storageURL = loaded.repository.fileURL
        self.input = loaded.input
        self.testing = loaded.testing
        // UI automation never asks for Touch ID.
        if loaded.testing { passwordsLock.authenticate = { _ in true } }
        let writer = SessionAutosaver(repository: loaded.repository, disabledReason: loaded.error)
        persistence = writer
        var snapshot = loaded.workspace
        if !preferences.restoreSession || snapshot.openProfileIDs.isEmpty {
            snapshot = snapshot.startingWithSavedItemsOnly()
        }
        // A closed profile keeps saved organization, not abandoned Today tabs.
        let active = snapshot.activeProfileID
        #if DEBUG
        // UI automation sees the welcome only when it asks to.
        let environment = ProcessInfo.processInfo.environment
        if loaded.testing, environment["EARLY_TEST_DEFAULTS_SUITE"] != nil, environment["EARLY_TEST_WELCOME"] == nil {
            defaults.set(true, forKey: BrowserWindowModel.welcomeCompletedKey)
        }
        #endif
        let startup = loaded.error == nil ? launchStore.claimStartupContext() : .returningSession
        workspace = snapshot
        if let journal = browserImportJournal {
            browserImportBatches = (try? await journal.entries().filter { $0.state == .complete }.map(\.batch)) ?? []
        }
        let primary = makeModel(session: snapshot.session(for: active)!, startup: startup)
        model = primary
        primaryWindowIsOpen = true
        attach(primary)
        var restored: [UUID] = []
        for session in snapshot.sessions where session.profileID == active || snapshot.openProfileIDs.contains(session.profileID) {
            let sessions = session.profileID == active ? session.additionalWindows : [session] + session.additionalWindows
            for window in sessions { restored.append(addWindow(session: window)) }
        }
        if !snapshot.openProfileIDs.contains(active) { snapshot.openProfileIDs.append(active) }
        workspace = snapshot
        pendingRestoredWindows = Set(restored)
        restoringFocus = !restored.isEmpty
        if !loaded.testing { updater = SoftwareUpdater(preferences: preferences) }
        preferences.onChange = { [weak self] key in
            if key == "browserAppearance" { self?.applyAppearance() }
            if ["checksForUpdatesAutomatically", "installsUpdatesAutomatically"].contains(key), let preferences = self?.preferences {
                self?.updater?.apply(preferences)
            }
            if ["onlineSearchSuggestions", "privateSearchSuggestions", "commandBarActions"].contains(key) { self?.visibleModels.forEach { $0.refreshSuggestions() } }
            if key == "spaceSwipes" { self?.visibleModels.forEach { $0.cancelSpaceSwipePresentation() } }
            if key == "searchEngine" { self?.visibleModels.forEach { $0.refreshSuggestions() } }
        }
        applyAppearance()
        save(primary)
        refreshDefaultBrowser()
        deliverExternalLinks()
        Task { await retryWebsiteDataCleanup() }
        return restored
    }

    func ensurePrimaryWindow() {
        guard !primaryWindowIsOpen, let workspace else { return }
        let session = workspace.session(for: workspace.defaultProfileID)!.savedItemsOnly
        let primary = makeModel(session: session)
        model = primary
        primaryWindowIsOpen = true
        attach(primary)
        self.workspace?.activeProfileID = workspace.defaultProfileID
        save(primary)
    }

    /// A fresh window shares saved organization/store identity, never another
    /// window's Today tabs, split membership, live views, or command-bar state.
    @discardableResult
    func openNewWindow(from source: BrowserWindowModel? = nil) -> UUID? {
        guard canOpenWindow, let workspace else { return nil }
        let template: BrowserSession
        // New Window from a private window opens an ordinary one.
        if let source, !source.isPrivate {
            guard visibleModels.contains(where: { $0 === source }) else { return nil }
            template = source.coordinator.session
        } else {
            guard let session = workspace.session(for: workspace.activeProfileID) else { return nil }
            template = session
        }
        let id = addWindow(session: template.savedItemsOnly)
        self.workspace?.activeProfileID = template.profileID
        saveAll()
        presentWindow?(id)
        return id
    }

    /// Opens a private window: its only Space is named "Private", it records
    /// no history, and nothing in it is saved, restored or kept on disk.
    /// It fills passwords saved in the profile it was opened from.
    @discardableResult
    func openPrivateWindow(from source: BrowserWindowModel? = nil) -> UUID? {
        guard canOpenWindow else { return nil }
        let profile = privateProfileID ?? UUID()
        privateProfileID = profile
        let passwordsFrom = source?.passwordsProfileID ?? workspace?.activeProfileID
        let id = addWindow(session: .privateWindow(profileID: profile), passwordsFrom: passwordsFrom)
        presentWindow?(id)
        return id
    }

    func isPrivateProfile(_ id: UUID) -> Bool { privateProfileID == id }

    var canReopenClosedWindow: Bool { canOpenWindow && !recentlyClosedWindows.isEmpty }

    /// Closed windows whose profile still exists, newest first.
    var recentlyClosedWindows: [ClosedWindow] {
        closedWindows.reversed().filter { closed in profiles.contains { $0.id == closed.session.profileID } }
    }

    func canReopenClosedWindow(_ id: UUID) -> Bool {
        canOpenWindow && recentlyClosedWindows.contains { $0.id == id }
    }

    /// Reopens one closed window, or the most recent whose profile still exists.
    @discardableResult
    func reopenClosedWindow(_ id: UUID? = nil) -> UUID? {
        guard canOpenWindow else { return nil }
        if let id {
            guard canReopenClosedWindow(id), let index = closedWindows.firstIndex(where: { $0.id == id }) else { return nil }
            return reopen(closedWindows.remove(at: index).session)
        }
        while let closed = closedWindows.popLast() {
            if let reopened = reopen(closed.session) { return reopened }
        }
        return nil
    }

    private func reopen(_ closed: BrowserSession) -> UUID? {
        guard let current = workspace?.session(for: closed.profileID) else { return nil }
        let id = addWindow(session: closed.reopeningWindow(savedItemsFrom: current))
        workspace?.activeProfileID = closed.profileID
        saveAll()
        presentWindow?(id)
        return id
    }

    /// The last private window closed: its cookies, storage and download list go.
    private func releasePrivateSessionIfUnused() {
        guard let profile = privateProfileID,
              !visibleModels.contains(where: { $0.coordinator.profileID == profile }) else { return }
        privateProfileID = nil
        privateDataStore = nil
        if #available(macOS 15.4, *) { privateExtensionHosts.values.forEach { ($0 as? ExtensionHost)?.unloadAll() } }
        privateExtensionHosts.removeAll()
        sitePermissionStores.removeValue(forKey: profile)
        localFileStores.removeValue(forKey: profile)
        downloadStores.removeValue(forKey: profile)?.cancelAll()
    }

    private func websiteDataStore(for id: UUID) -> WKWebsiteDataStore {
        if id == privateProfileID {
            if let privateDataStore { return privateDataStore }
            let store = WKWebsiteDataStore.nonPersistent()
            privateDataStore = store
            return store
        }
        if let store = dataStores[id] { return store }
        let store = testing ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    func downloads(for id: UUID) -> DownloadStore {
        if let store = downloadStores[id] { return store }
        // UI automation never writes into the user's Downloads folder.
        let directory = testing ? FileManager.default.temporaryDirectory
            .appending(path: "EarlyTestDownloads/\(UUID().uuidString)", directoryHint: .isDirectory) : nil
        let store = DownloadStore(directory: directory)
        store.recordsSourceAddresses = id != privateProfileID
        store.dataStoreProvider = { [weak self] in self?.websiteDataStore(for: id) }
        downloadStores[id] = store
        return store
    }

    var hasActiveDownloads: Bool { downloadStores.values.contains { $0.hasActiveDownloads } }

    private func historyFile(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "History/\(id.uuidString).sqlite", directoryHint: .notDirectory)
    }

    private func sitePermissionsFile(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "Permissions/\(id.uuidString).json", directoryHint: .notDirectory)
    }

    func sitePermissions(for id: UUID) -> SitePermissions {
        if let store = sitePermissionStores[id] { return store }
        let store = SitePermissions(fileURL: isPrivateProfile(id) ? nil : sitePermissionsFile(for: id))
        sitePermissionStores[id] = store
        return store
    }

    private func localFilesFile(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "LocalFiles/\(id.uuidString).plist", directoryHint: .notDirectory)
    }

    /// A profile's local-file bookmarks, keeping only those its tabs still need.
    func localFiles(for id: UUID) -> LocalFileBookmarks? {
        if let store = localFileStores[id] { return store }
        let store = LocalFileBookmarks(fileURL: isPrivateProfile(id) ? nil : localFilesFile(for: id))
        if let session = workspace?.session(for: id) {
            let sessions = [session] + session.additionalWindows
            store.keepOnly(sessions.flatMap { window in
                (window.tabs + window.recentlyClosed.map(\.tab)).flatMap { [$0.currentURL] + ($0.pinnedURL.map { [$0] } ?? []) }
            })
        }
        localFileStores[id] = store
        return store
    }

    private func passwordsFile(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "\(Self.passwordsFolder)/\(id.uuidString).vault", directoryHint: .notDirectory)
    }

    /// Development builds share a release's data folder but keep their own
    /// passwords, under their own key, so they never re-encrypt a release's.
    #if DEBUG
    static let passwordsFolder = "Passwords/Development"
    #else
    static let passwordsFolder = "Passwords"
    #endif

    /// A profile's saved passwords. Private sessions have none of their own.
    func passwords(for id: UUID) -> PasswordVault? {
        if let vault = passwordVaults[id] { return vault }
        guard !isPrivateProfile(id), profiles.contains(where: { $0.id == id }) else { return nil }
        // UI automation keeps passwords in memory and never uses the Keychain.
        let vault = testing ? PasswordVault(fileURL: nil, key: nil)
            : PasswordVault(fileURL: passwordsFile(for: id), key: vaultKey(for: id))
        passwordVaults[id] = vault
        return vault
    }

    /// Releases keep the passwords' key in the Keychain. Development builds
    /// keep theirs in a file beside their own vaults: to the Keychain each new
    /// build is a different app, so it would ask for your password every time.
    private func vaultKey(for id: UUID) -> any PasswordVaultKey {
        #if DEBUG
        if let directory = storageURL?.deletingLastPathComponent() {
            return FileVaultKey(file: directory.appending(path: "\(Self.passwordsFolder)/Key", directoryHint: .notDirectory), profile: id)
        }
        #endif
        return KeychainVaultKey(profile: id)
    }

    /// Settings › Passwords for a profile, searching for a website.
    func showPasswords(profileID: UUID?, search: String? = nil) {
        passwordsProfileID = profileID ?? workspace?.activeProfileID
        passwordSearch = search ?? ""
        settingsSection = .passwords
        presentSettingsWindow?()
    }

    /// A site's icon from a window of the profile, if one has it.
    func favicon(for url: URL, profileID: UUID) -> NSImage? {
        visibleModels.lazy.filter { $0.coordinator.profileID == profileID }.compactMap { $0.webViews.favicons.image(for: url) }.first
    }

    private func extensionsFile(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "Extensions/\(id.uuidString).json", directoryHint: .notDirectory)
    }

    /// Folder and ZIP installs, copied per profile.
    private func extensionFilesDirectory(for id: UUID) -> URL? {
        storageURL?.deletingLastPathComponent().appending(path: "Extensions/Files/\(id.uuidString)", directoryHint: .isDirectory)
    }

    func extensionCatalog(for id: UUID) -> ExtensionCatalog {
        if let catalog = extensionCatalogs[id] { return catalog }
        let catalog = ExtensionCatalog(fileURL: extensionsFile(for: id))
        extensionCatalogs[id] = catalog
        return catalog
    }

    /// A profile's extension host, made when it's first needed. A private
    /// window's runs those of the profile it came from that are allowed in
    /// private windows, on the private session's data, and keeps nothing.
    func extensionHost(for profile: UUID, from source: UUID? = nil) -> AnyObject? {
        guard #available(macOS 15.4, *) else { return nil }
        let isPrivate = isPrivateProfile(profile)
        guard let owner = isPrivate ? source : profile, profiles.contains(where: { $0.id == owner }) else { return nil }
        if let host = (isPrivate ? privateExtensionHosts : extensionHosts)[owner] { return host }
        let host = ExtensionHost(catalog: extensionCatalog(for: owner), filesDirectory: extensionFilesDirectory(for: owner),
                                 websiteDataStore: websiteDataStore(for: profile),
                                 storageIdentifier: testing || isPrivate ? nil : owner, isPrivate: isPrivate)
        configureExtensions(host)
        if isPrivate { privateExtensionHosts[owner] = host } else { extensionHosts[owner] = host }
        Task { await host.loadEnabled() }
        return host
    }

    /// The hosts running a profile's extensions: its own and its private windows'.
    @available(macOS 15.4, *)
    func runningExtensionHosts(of profile: UUID) -> [ExtensionHost] {
        [extensionHosts[profile], privateExtensionHosts[profile]].compactMap { $0 as? ExtensionHost }
    }

    /// The profile whose extensions a window runs.
    func extensionsProfileID(of model: BrowserWindowModel) -> UUID? {
        model.isPrivate ? model.passwordsProfileID : model.coordinator.profileID
    }

    /// Settings › Extensions for a profile.
    func showExtensions(profileID: UUID?) {
        extensionsProfileID = profileID ?? workspace?.activeProfileID
        settingsSection = .extensions
        presentSettingsWindow?()
    }

    @available(macOS 15.4, *)
    private func configureExtensions(_ host: ExtensionHost) {
        host.openTab = { [weak self, weak host] url, window, active in
            guard let self, let host else { return nil }
            if let owner = (window?.owner as? BrowserWindowModel) ?? self.extensionModels(of: host).first {
                return owner.openExtensionTab(url, active: active)
            }
            return self.openExtensionWindow(for: host, url: url)?.activeTab
        }
        host.openWindow = { [weak self, weak host] url in
            guard let self, let host else { return nil }
            return self.openExtensionWindow(for: host, url: url)
        }
        host.presentPopup = { [weak self, weak host] action in
            guard let self, let host,
                  let owner = (host.focusedWindow?.owner as? BrowserWindowModel) ?? self.extensionModels(of: host).first
            else { return false }
            return owner.presentExtensionPopup(action)
        }
        host.askForAccess = { [weak self] name, request in await self?.askForExtensionAccess(name, request) ?? false }
        host.onLoad = { [weak self, weak host] base in
            guard let self, let host else { return }
            for owner in self.extensionModels(of: host) { owner.reloadExtensionPages(from: base) }
        }
    }

    private func extensionModels(of host: AnyObject) -> [BrowserWindowModel] {
        visibleModels.filter { $0.extensionHost === host }
    }

    /// A window an extension asked for, in the host's profile (or private session).
    @available(macOS 15.4, *)
    private func openExtensionWindow(for host: ExtensionHost, url: URL?) -> ExtensionWindow? {
        let source = extensionModels(of: host).first
        var id: UUID?
        if host.isPrivate {
            guard let source else { return nil }
            id = openPrivateWindow(from: source)
        } else if let source {
            id = openNewWindow(from: source)
        } else if canOpenWindow, let profile = extensionHosts.first(where: { $0.value === host })?.key,
                  let session = workspace?.session(for: profile) {
            let window = addWindow(session: session.savedItemsOnly)
            saveAll()
            presentWindow?(window)
            id = window
        }
        guard let id, let model = windowModel(id) else { return nil }
        if let url { _ = model.openExtensionTab(url, active: true) }
        return model.extensionWindow as? ExtensionWindow
    }

    /// An extension's own page, such as its options, in a window of its profile.
    @available(macOS 15.4, *)
    func openExtensionPage(_ url: URL, profile: UUID) {
        guard let host = extensionHost(for: profile) as? ExtensionHost else { return }
        if let owner = (host.focusedWindow?.owner as? BrowserWindowModel) ?? extensionModels(of: host).first {
            owner.openExtensionTab(url, active: true)
            owner.extensionFocusWindow()
        } else {
            _ = openExtensionWindow(for: host, url: url)
        }
    }

    /// A window model's native window.
    func nativeWindow(of owner: BrowserWindowModel) -> NSWindow? {
        if owner === model, primaryWindowIsOpen { return nativeWindow(id: nil) }
        guard let entry = windows.first(where: { $0.model === owner }) else { return nil }
        return nativeWindow(id: entry.id)
    }

    /// The native window of the primary window (nil) or another one: as it
    /// registered, or by the name Early gave it.
    private func nativeWindow(id: UUID?) -> NSWindow? {
        if let window = nativeWindows.first(where: { $0.id == id })?.window { return window }
        let identifier = id.map { "browser.\($0)" } ?? "browser"
        return NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }

    /// An extension asks for more than it was given. Tests never see a prompt.
    private func askForExtensionAccess(_ name: String, _ request: String) async -> Bool {
        guard !testing else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow “\(name)” to \(request)?"
        alert.informativeText = "You can change this later in Settings › Extensions."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Settings › Privacy

    /// Websites that stored data in a profile.
    func websiteData(for profile: UUID) async -> [WKWebsiteDataRecord] {
        guard profiles.contains(where: { $0.id == profile }) else { return [] }
        return await websiteDataStore(for: profile).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    }

    func removeWebsiteData(_ records: [WKWebsiteDataRecord], profile: UUID) async {
        guard profiles.contains(where: { $0.id == profile }), !records.isEmpty else { return }
        await websiteDataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    /// Clears a profile's history and website data from the period's start:
    /// through one of its windows (which also clears their icons), or
    /// directly when none is open.
    func clearHistory(_ range: HistoryClearRange, profile: UUID) async {
        if let owner = visibleModels.first(where: { $0.coordinator.profileID == profile && !$0.isPrivate }) {
            await owner.clearHistory(range)
            return
        }
        guard profiles.contains(where: { $0.id == profile }) else { return }
        let since = range.start(now: Date())
        try? await history(for: profile)?.deleteVisits(since: since)
        await websiteDataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since ?? .distantPast)
    }

    /// A profile's open pull requests.
    func pullRequests(for profile: UUID) -> PullRequestFeed? {
        if let feed = pullRequestFeeds[profile] { return feed }
        guard !isPrivateProfile(profile), profiles.contains(where: { $0.id == profile }) else { return nil }
        let feed: PullRequestFeed
        if let pullRequestReader { feed = PullRequestFeed(read: pullRequestReader) }
        else if testing { feed = PullRequestFeed(read: { _ in [:] }) }
        else { feed = PullRequestFeed(dataStore: { [weak self] in self?.websiteDataStore(for: profile) }) }
        feed.onUpdate = { [weak self] in self?.applyPullRequests(profile: profile) }
        pullRequestFeeds[profile] = feed
        return feed
    }

    /// A feed runs while one of its profile's open windows has a GitHub live
    /// folder; otherwise it stops and forgets what it read (the pins stay).
    private func updatePullRequestFeeds() {
        guard let workspace else { return }
        for profile in workspace.profiles.map(\.id) {
            let open = visibleModels.contains { $0.coordinator.profileID == profile && !$0.isPrivate }
            let intervals = (workspace.session(for: profile)?.folders ?? []).compactMap { folder in
                folder.live?.source == .githubPullRequests ? folder.live?.interval.seconds : nil
            }
            // One read serves every folder, so the most frequent choice wins.
            if open, let interval = intervals.min(), let feed = pullRequests(for: profile) {
                feed.interval = interval
                feed.start()
            } else {
                pullRequestFeeds[profile]?.stop()
            }
        }
    }

    /// The profile's live folders follow what was read. One window changes
    /// them; saving shares the pins with its other windows.
    func applyPullRequests(profile: UUID) {
        guard let feed = pullRequestFeeds[profile],
              let owner = visibleModels.first(where: { $0.coordinator.profileID == profile && !$0.isPrivate }) else { return }
        owner.applyPullRequests(feed)
    }

    /// Signing in to GitHub in a tab: a signed-out folder reads it again.
    func noteVisit(_ url: URL, profile: UUID) {
        guard let feed = pullRequestFeeds[profile], feed.status == .signedOut,
              url.host?.lowercased() == PullRequest.github.host, !url.path.hasPrefix("/login"),
              !url.path.hasPrefix("/session") else { return }
        feed.refresh()
    }

    // MARK: Export and import

    /// What an export holds right now: every profile's Spaces, folders,
    /// pins, Favorites, windows and open tabs, and the settings that move.
    func stateArchive() -> EarlyStateArchive? {
        captureWorkspace()
        guard let workspace else { return nil }
        return EarlyStateArchive(workspace: workspace, settings: preferences?.portableSettings)
    }

    /// A file to import, checked in full before anything changes.
    func readStateArchive(at url: URL) throws -> EarlyStateArchive {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > EarlyStateArchive.maximumSize {
            throw EarlyStateArchive.Problem.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw EarlyStateArchive.Problem.notAnArchive }
        return try EarlyStateArchive.decode(data, using: input)
    }

    /// The password, privacy and update settings a file would change here.
    func sensitiveImportChanges(from settings: PortableSettings) -> [(title: String, value: Bool)] {
        preferences?.sensitiveChanges(from: settings) ?? []
    }

    /// Copies of what was here before each import, newest kept.
    var backupsDirectory: URL? { storageURL?.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory) }
    static let backupLimit = 5

    private var browserImportJournal: BrowserImportJournal? {
        storageURL.map { BrowserImportJournal(directory: $0.deletingLastPathComponent().appendingPathComponent("BrowserImports")) }
    }

    /// All entry points share the Settings-hosted flow, including File and Welcome.
    func showBrowserImport() {
        guard canEditProfiles else { return }
        settingsSection = .sessions
        browserImportPresented = true
        presentSettingsWindow?()
    }

    func browserImportValidation() -> NavigationInput { input }

    func browserImportSnapshot() -> BrowserWorkspace? { captureWorkspace(); return workspace }

    func importBrowser(_ document: BrowserImportDocument, selected: Set<String>,
                       destinations: [String: BrowserImportDestination], flatten: Bool) async -> ImportOutcome {
        guard canEditProfiles, let journal = browserImportJournal else {
            return .init(message: "Early can’t import right now. Try again in a moment.", succeeded: false)
        }
        profileOperationInProgress = true
        applyingWorkspace = true
        defer { applyingWorkspace = false; profileOperationInProgress = false; saveAll(); deliverExternalLinks() }
        var batch: BrowserImportBatch?
        do {
            guard await persistence?.flush() == true else { throw SessionError.database(persistence?.error ?? "Couldn’t save the current session.") }
            captureWorkspace()
            guard let current = workspace else { throw BrowserImportProblem.invalid }
            guard try await journal.entries().count < 128 else { throw BrowserImportProblem.capacity }
            let validationInput = input
            var candidate = try await Task.detached {
                try document.candidate(into: current, selecting: selected, destinations: destinations, flattenDeepFolders: flatten, using: validationInput)
            }.value
            try Task.checkCancellation()
            // A recoverable backup must be durable before the first history insertion.
            let backupDirectory = backupsDirectory!
            let backupBatchID = candidate.batch.id
            let backup = try await Task.detached {
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let url = backupDirectory.appendingPathComponent("Before Import \(formatter.string(from: Date())) \(backupBatchID).json")
                try EarlyStateArchive(workspace: current, settings: nil).encoded().write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.synchronize()
                let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("Before Import ") && $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for old in backups.dropLast(5) where old != url { try FileManager.default.removeItem(at: old) }
                return url
            }.value
            try await journal.write(.init(batch: candidate.batch, state: .importing))
            batch = candidate.batch
            var importedVisits = 0
            for (profile, visits) in candidate.history {
                guard let file = historyFile(for: profile) else { throw BrowserImportProblem.invalid }
                let store = historyStores[profile] ?? HistoryStore(fileURL: file)
                importedVisits += try await store.importVisits(visits, batchID: candidate.batch.id)
            }
            try Task.checkCancellation()
            // Incorporate any page metadata/selection changes that arrived while reading.
            captureWorkspace()
            guard let latest = workspace else { throw BrowserImportProblem.invalid }
            let rebased = try candidate.adding(to: latest, using: input)
            candidate.batch = candidate.batch.adjustedPositions(in: rebased)
            try await journal.write(.init(batch: candidate.batch, state: .importing))
            batch = candidate.batch
            persistence?.enqueue(rebased)
            guard await persistence?.flush() == true else { throw SessionError.database(persistence?.error ?? "Couldn’t save the import.") }
            // The marker and organization are now durable. Never roll history back after this point.
            batch = nil
            captureWorkspace()
            let live = (try? candidate.adding(to: workspace ?? latest, using: input)) ?? rebased
            workspace = live
            for session in live.sessions {
                let owners = visibleModels.filter { $0.coordinator.profileID == session.profileID }
                for (owner, snapshot) in zip(owners, [session] + session.additionalWindows) {
                    owner.applyProfileSnapshot(snapshot)
                    owner.historyRevision += 1
                    owner.refreshRecentPages()
                }
            }
            // If this small final journal write fails, startup uses the durable marker to finish it.
            try? await journal.write(.init(batch: candidate.batch, state: .complete))
            browserImportBatches.insert(candidate.batch, at: 0)
            let pages = candidate.batch.tabs.count, folders = candidate.batch.folders.count
            return .init(message: "Imported \(pages) \(pages == 1 ? "page" : "pages"), \(folders) \(folders == 1 ? "folder" : "folders") and \(importedVisits) \(importedVisits == 1 ? "visit" : "visits"). Pages load only when chosen. Undo Import is available here, including after restarting Early.", succeeded: true, backup: backup)
        } catch {
            if let batch {
                do {
                    for profile in batch.historyProfiles {
                        if let file = historyFile(for: profile) {
                            try await (historyStores[profile] ?? HistoryStore(fileURL: file)).undoBrowserImport(batch.id)
                        }
                    }
                    try await journal.remove(batch.id)
                } catch {
                    browserImportError = "Import recovery is pending. Early will retry safely at its next launch. \(error.localizedDescription)"
                }
            }
            return .init(message: "Import could not finish. \(error.localizedDescription)", succeeded: false)
        }
    }

    func undoBrowserImport(_ batch: BrowserImportBatch) async -> ImportOutcome {
        guard canEditProfiles, let journal = browserImportJournal else {
            return .init(message: "Early can’t undo an import right now.", succeeded: false)
        }
        profileOperationInProgress = true; applyingWorkspace = true
        defer { applyingWorkspace = false; profileOperationInProgress = false; saveAll(); deliverExternalLinks() }
        do {
            guard await persistence?.flush() == true else { throw SessionError.database("The current session couldn’t be saved.") }
            captureWorkspace()
            guard let current = workspace else { throw BrowserImportProblem.invalid }
            let committed = current.browserImportBatchIDs?.contains(batch.id) == true
            if !committed {
                // A prior undo may have committed its workspace before a disk
                // error interrupted history cleanup. Retry only that cleanup.
                guard try await journal.entries().contains(where: { $0.batch.id == batch.id && $0.state == .undoing }) else { throw BrowserImportProblem.invalid }
            }
            let result = try batch.undo(in: current, using: input)
            try await journal.write(.init(batch: batch, state: .undoing))
            persistence?.enqueue(result.workspace)
            guard await persistence?.flush() == true else { throw SessionError.database(persistence?.error ?? "Undo couldn’t be saved.") }
            captureWorkspace()
            let live = (try? batch.undo(in: workspace ?? current, using: input).workspace) ?? result.workspace
            workspace = live
            for session in live.sessions {
                for (owner, snapshot) in zip(visibleModels.filter { $0.coordinator.profileID == session.profileID }, [session] + session.additionalWindows) {
                    owner.applyProfileSnapshot(snapshot); owner.historyRevision += 1; owner.refreshRecentPages()
                }
            }
            for profile in batch.historyProfiles {
                if let file = historyFile(for: profile) { try await (historyStores[profile] ?? HistoryStore(fileURL: file)).undoBrowserImport(batch.id) }
            }
            try await journal.remove(batch.id)
            browserImportBatches.removeAll { $0.id == batch.id }
            return .init(message: "Import undone. \(result.preserved) edited or used pages were kept. Profiles and website data were preserved.", succeeded: true)
        } catch { return .init(message: "Undo could not finish. It is safe to retry or restart Early. \(error.localizedDescription)", succeeded: false) }
    }

    struct ImportOutcome: Equatable {
        let message: String
        let succeeded: Bool
        /// What was here before, to import again if needed.
        var backup: URL?
    }

    /// The whole result is checked, a backup of what's here is saved, then
    /// every window changes at once. Nothing changes if any step fails.
    func importState(_ archive: EarlyStateArchive, mode: EarlyStateArchive.ImportMode, includeSettings: Bool,
                     includeSensitiveSettings: Bool = false) async -> ImportOutcome {
        guard canEditProfiles, let preferences else {
            return ImportOutcome(message: "Early can’t import right now. Try again in a moment.", succeeded: false)
        }
        guard !visibleModels.contains(where: {
            $0.webViews.pages.values.contains(where: \.hasDialog) || $0.sidebarInteractionInProgress || $0.splitResize != nil
        }) else {
            return ImportOutcome(message: "Close any open website dialogs, then import again.", succeeded: false)
        }
        captureWorkspace()
        guard let current = workspace else { return ImportOutcome(message: EarlyStateArchive.Problem.invalid.message, succeeded: false) }
        let result: EarlyStateArchive.ImportResult
        do { result = try archive.merged(into: current, mode: mode, using: input) }
        catch { return ImportOutcome(message: (error as? EarlyStateArchive.Problem ?? .invalid).message, succeeded: false) }
        let backup: URL
        do { backup = try writeBackup(EarlyStateArchive(workspace: current, settings: preferences.portableSettings)) }
        catch {
            return ImportOutcome(message: "Nothing was imported, because a backup of what you have couldn’t be saved. \(error.localizedDescription)",
                                 succeeded: false)
        }
        profileOperationInProgress = true
        defer {
            applyingWorkspace = false
            profileOperationInProgress = false
            deliverExternalLinks()
        }
        applyingWorkspace = true
        // Commit the validated replacement before discarding live documents or
        // changing settings. A locked/full/unavailable database leaves the
        // existing workspace and its windows usable, with the backup intact.
        persistence?.enqueue(result.workspace)
        guard await persistence?.flush() == true else {
            return ImportOutcome(message: "Nothing was imported because the session couldn’t be saved. \(persistence?.error ?? "")",
                                 succeeded: false, backup: backup)
        }
        workspace = result.workspace
        var opening: [BrowserSession] = []
        for profile in result.profiles {
            guard let session = result.workspace.session(for: profile) else { continue }
            let snapshots = [session] + session.additionalWindows
            let open = visibleModels.filter { $0.coordinator.profileID == profile }
            if !open.isEmpty {
                // A replaced profile's windows show what was imported; any
                // extra ones close, and the backup keeps what they had.
                for (owner, snapshot) in zip(open, snapshots) { owner.applyProfileSnapshot(snapshot) }
                for owner in open.dropFirst(snapshots.count) { closeWindow(of: owner) }
                opening += snapshots.dropFirst(open.count)
            } else if result.openProfiles.contains(profile) {
                opening += snapshots
            }
        }
        let opened = opening.map { addWindow(session: $0) }
        applyingWorkspace = false
        if includeSettings, let settings = archive.settings { preferences.apply(settings, includingSensitive: includeSensitiveSettings) }
        saveAll()
        opened.forEach { presentWindow?($0) }
        let names = result.profiles.compactMap { id in profiles.first { $0.id == id }?.name }
        let imported = names.count == 1 ? names[0] : "\(names.count) profiles"
        guard await persistence?.flush() == true else {
            return ImportOutcome(message: "Imported \(imported), but it couldn’t be saved yet. \(persistence?.error ?? "")",
                                 succeeded: true, backup: backup)
        }
        return ImportOutcome(message: "Imported \(imported). Tabs load when you choose them, and websites will ask you to sign in again.",
                             succeeded: true, backup: backup)
    }

    private func writeBackup(_ archive: EarlyStateArchive) throws -> URL {
        guard let directory = backupsDirectory else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var file = directory.appending(path: "Before Import \(formatter.string(from: archive.exportedAt)).json")
        if FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "Before Import \(formatter.string(from: archive.exportedAt)) \(UUID().uuidString.prefix(4)).json")
        }
        try archive.encoded().write(to: file, options: .atomic)
        let backups = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Before Import ") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in backups.dropLast(Self.backupLimit) where old != file { try? FileManager.default.removeItem(at: old) }
        return file
    }

    /// Closes a browser window as if its close button were pressed.
    private func closeWindow(of owner: BrowserWindowModel) {
        let id: UUID?
        if owner === model, primaryWindowIsOpen { id = nil }
        else if let entry = windows.first(where: { $0.model === owner }) { id = entry.id }
        else { return }
        nativeWindow(of: owner)?.close()
        closeWindow(id)
    }

    func history(for id: UUID) -> HistoryStore? {
        if let store = historyStores[id] { return store }
        guard profiles.contains(where: { $0.id == id }), let file = historyFile(for: id) else { return nil }
        let store = HistoryStore(fileURL: file)
        historyStores[id] = store
        return store
    }

    private func makeModel(session: BrowserSession, startup: StartupContext = .returningSession,
                           passwordsFrom: UUID? = nil) -> BrowserWindowModel {
        let isPrivate = isPrivateProfile(session.profileID)
        let passwordsProfile = isPrivate ? passwordsFrom : session.profileID
        return BrowserWindowModel(startup: startup, session: session, repository: repository!, input: input, isTesting: testing,
            restorationError: persistence?.error, defaults: defaults, sharedPersistence: persistence,
            websiteDataStore: websiteDataStore(for: session.profileID), downloads: downloads(for: session.profileID),
            preferences: preferences, isPrivate: isPrivate, history: history(for: session.profileID),
            sitePermissions: sitePermissions(for: session.profileID),
            passwords: passwordsProfile.flatMap { passwords(for: $0) }, passwordsProfileID: passwordsProfile,
            extensionHost: extensionHost(for: session.profileID, from: passwordsProfile),
            localFiles: localFiles(for: session.profileID))
    }

    @discardableResult private func addWindow(session: BrowserSession, passwordsFrom: UUID? = nil) -> UUID {
        let id = UUID()
        let child = makeModel(session: session, passwordsFrom: passwordsFrom)
        windows.append(WindowEntry(id: id, model: child))
        attach(child)
        return id
    }

    private func attach(_ owner: BrowserWindowModel) {
        owner.application = self
        // A private window is never written to the session file.
        owner.onSave = owner.isPrivate ? nil : { [weak self] source in self?.save(source) }
        owner.onOpenWindow = { [weak self, weak owner] url, title in
            guard let self, let owner, !self.isTerminating, (try? owner.input.validate(url)) != nil,
                  self.visibleModels.contains(where: { $0 === owner }) else { return }
            let id = self.addWindow(session: owner.coordinator.session.openingWindow(at: url, title: title))
            self.save(owner)
            self.presentWindow?(id)
        }
        owner.onOpenSettings = { [weak self, weak owner] in
            guard let self, let owner, !self.isTerminating,
                  self.visibleModels.contains(where: { $0 === owner }) else { return }
            self.presentSettingsWindow?()
        }
    }

    private func captureWorkspace(preferred: BrowserWindowModel? = nil) {
        guard var snapshot = workspace else { return }
        for index in snapshot.sessions.indices {
            let id = snapshot.sessions[index].profileID
            var models = visibleModels.filter { $0.coordinator.profileID == id }
            if let preferred, let position = models.firstIndex(where: { $0 === preferred }) {
                models.insert(models.remove(at: position), at: 0)
            }
            guard let first = models.first else { continue }
            var session = first.coordinator.session
            session.additionalWindows = models.dropFirst().map { $0.coordinator.session }
            snapshot.sessions[index] = session
        }
        let open = Set(visibleModels.map { $0.coordinator.profileID })
        snapshot.openProfileIDs = snapshot.profiles.map(\.id).filter { open.contains($0) }
        if !open.contains(snapshot.activeProfileID), let first = snapshot.openProfileIDs.first { snapshot.activeProfileID = first }
        workspace = snapshot
    }

    private func save(_ source: BrowserWindowModel) {
        guard !applyingWorkspace, !isTerminating, visibleModels.contains(where: { $0 === source }) else { return }
        let session = source.coordinator.session
        for target in visibleModels where target !== source && target.coordinator.profileID == source.coordinator.profileID {
            target.synchronizeSavedItems(from: session)
        }
        saveAll()
    }

    func saveAll() {
        guard !applyingWorkspace else { return }
        captureWorkspace()
        if let workspace { persistence?.enqueue(workspace) }
        updatePullRequestFeeds()
    }

    /// Every tab, pin and Favorite address in the profile's open windows.
    func sidebarURLs(profileID: UUID) -> [URL] {
        visibleModels.filter { $0.coordinator.profileID == profileID }.flatMap(\.sidebarURLs)
    }

    /// One window cleared the profile's shared website data; the others drop
    /// icons of sites no longer in the sidebar and reload History.
    func didClearWebsiteData(profileID: UUID, from source: BrowserWindowModel) {
        let kept = sidebarURLs(profileID: profileID)
        for target in visibleModels where target !== source && target.coordinator.profileID == profileID {
            target.webViews.forgetClearedArtwork(keepingIconsFor: kept)
            target.historyRevision += 1
            target.refreshRecentPages()
        }
    }

    func focusedWindow(_ id: UUID?) {
        // Another window of the profile may have added to its history.
        windowModel(id)?.refreshRecentPages()
        windowModel(id)?.extensionWindowDidFocus()
        if let owner = windowModel(id), !owner.isPrivate { pullRequestFeeds[owner.coordinator.profileID]?.refreshIfStale() }
        guard !restoringFocus, let owner = windowModel(id), !owner.isPrivate,
              workspace?.activeProfileID != owner.coordinator.profileID else { return }
        workspace?.activeProfileID = owner.coordinator.profileID
        saveAll()
    }

    func windowDidRegister(_ id: UUID?, window: NSWindow? = nil) {
        if let window {
            nativeWindows.removeAll { $0.window == nil || $0.window === window || $0.id == id }
            nativeWindows.append(NativeWindow(id: id, window: window))
        }
        // A new window can become key before it has registered.
        updateFrontWindow()
        if let id { pendingRestoredWindows.remove(id) }
        guard restoringFocus, pendingRestoredWindows.isEmpty else { return }
        restoringFocus = false
        // Restoring another profile's background windows must not replace the
        // profile that was frontmost when Early quit.
        DispatchQueue.main.async { [weak self] in
            guard self?.primaryWindowIsOpen == true else { return }
            self?.nativeWindow(id: nil)?.makeKeyAndOrderFront(nil)
        }
    }

    func openProfile(_ id: UUID) {
        guard !isTerminating, !profileOperationInProgress, let session = workspace?.session(for: id) else { return }
        let window: NSWindow?
        if let model, primaryWindowIsOpen, model.coordinator.profileID == id { window = nativeWindow(id: nil) }
        else if let existing = windows.first(where: { $0.model.coordinator.profileID == id }) { window = nativeWindow(id: existing.id) }
        else {
            // Its windows as they were saved, or as they were imported.
            let opened = ([session] + session.additionalWindows).map { addWindow(session: $0) }
            workspace?.activeProfileID = id
            saveAll()
            opened.forEach { presentWindow?($0) }
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace?.activeProfileID = id
        saveAll()
    }

    @discardableResult func createProfile(name: String, color: BrowserSpace.Color) -> UUID? {
        guard canEditProfiles else { return nil }
        let id = workspace?.createProfile(name: name, color: color)
        if id != nil { saveAll() }
        return id
    }

    @discardableResult func editProfile(_ id: UUID, name: String, color: BrowserSpace.Color) -> Bool {
        guard canEditProfiles, workspace?.editProfile(id, name: name, color: color) == true else { return false }
        saveAll()
        return true
    }

    @discardableResult func setDefaultProfile(_ id: UUID) -> Bool {
        guard canEditProfiles, workspace?.setDefaultProfile(id) == true else { return false }
        saveAll()
        return true
    }

    func showSpaceEditor(profileID: UUID, spaceID: UUID?) {
        guard canEditProfiles else { return }
        openProfile(profileID)
        guard let owner = visibleModels.first(where: { $0.coordinator.profileID == profileID }) else { return }
        if let spaceID { owner.requestEditSpace(spaceID, selectOnSave: true) }
        else { owner.requestNewSpace() }
    }

    /// Cross-profile reassignment is an explicit reload, never a transplant of
    /// WebKit views or cookies. Unrelated pages retain their live view identity.
    func moveSpace(_ id: UUID, from owner: BrowserWindowModel, to profileID: UUID,
                   name: String, color: BrowserSpace.Color, icon: SpaceIcon?) -> Bool {
        guard canEditProfiles, !visibleModels.contains(where: {
            $0.webViews.pages.values.contains(where: \.hasDialog) || $0.sidebarInteractionInProgress || $0.splitResize != nil
        }) else { return false }
        captureWorkspace(preferred: owner)
        guard var draft = workspace, let source = draft.sessions.firstIndex(where: { $0.profileID == owner.coordinator.profileID }),
              let space = draft.sessions[source].spaces.firstIndex(where: { $0.id == id }),
              let normalized = BrowserSpace.normalizedName(name) else { return false }
        for index in draft.sessions[source].additionalWindows.indices {
            let local = draft.sessions[source].additionalWindows[index].spaces.firstIndex { $0.id == id }!
            draft.sessions[source].additionalWindows[index].spaces[local].name = normalized
            draft.sessions[source].additionalWindows[index].spaces[local].color = color
            draft.sessions[source].additionalWindows[index].spaces[local].icon = icon
        }
        draft.sessions[source].spaces[space].name = normalized
        draft.sessions[source].spaces[space].color = color
        draft.sessions[source].spaces[space].icon = icon
        guard draft.moveSpace(id, from: owner.coordinator.profileID, to: profileID, using: input) else { return false }
        applyingWorkspace = true
        workspace = draft
        for session in draft.sessions where session.profileID == owner.coordinator.profileID || session.profileID == profileID {
            var models = visibleModels.filter { $0.coordinator.profileID == session.profileID }
            if let index = models.firstIndex(where: { $0 === owner }) { models.insert(models.remove(at: index), at: 0) }
            for (target, snapshot) in zip(models, [session] + session.additionalWindows) { target.applyProfileSnapshot(snapshot) }
        }
        applyingWorkspace = false
        openProfile(profileID)
        saveAll()
        return true
    }

    func deleteProfile(_ id: UUID) async {
        guard canEditProfiles else { return }
        guard id != workspace?.defaultProfileID else {
            profileError = "The Default profile cannot be deleted. You can rename it instead."
            return
        }
        guard !visibleModels.contains(where: { $0.coordinator.profileID == id && $0.webViews.pages.values.contains(where: \.hasDialog) }) else {
            profileError = "Close this profile’s dialogs before deleting it."
            return
        }
        captureWorkspace()
        guard var draft = workspace, draft.deleteProfile(id) else { return }
        profileOperationInProgress = true
        defer {
            applyingWorkspace = false
            profileOperationInProgress = false
            deliverExternalLinks()
        }
        // Record cleanup before removing metadata; a failed save must never
        // delete a website store still referenced by the on-disk catalog.
        var pending = defaults.stringArray(forKey: "pendingProfileCleanup") ?? []
        if !pending.contains(id.uuidString) { pending.append(id.uuidString) }
        defaults.set(pending, forKey: "pendingProfileCleanup")
        applyingWorkspace = true
        persistence?.enqueue(draft)
        guard await persistence?.flush() == true else {
            profileError = "The profile could not be deleted because the session couldn’t be saved. Its windows and data were kept. \(persistence?.error ?? "")"
            return
        }
        // The on-disk catalog no longer references this profile. Only now may
        // its windows, credentials, extension data and permissions be removed.
        workspace = draft
        profileError = nil
        let icons = visibleModels.filter { $0.coordinator.profileID == id }.map { $0.webViews.favicons }
        let closing = windows.filter { $0.model.coordinator.profileID == id }.map(\.id)
        for windowID in closing {
            nativeWindow(id: windowID)?.close()
            closeWindow(windowID)
        }
        if model?.coordinator.profileID == id {
            nativeWindow(id: nil)?.close()
            closeWindow(nil)
        }
        dataStores.removeValue(forKey: id)
        downloadStores.removeValue(forKey: id)?.cancelAll()
        let history = historyStores.removeValue(forKey: id)
        sitePermissionStores.removeValue(forKey: id)?.removeFile()
        localFileStores.removeValue(forKey: id)?.removeFile()
        if let file = localFilesFile(for: id) { try? FileManager.default.removeItem(at: file) }
        if #available(macOS 15.4, *) {
            (privateExtensionHosts.removeValue(forKey: id) as? ExtensionHost)?.unloadAll()
            // Without a host this run, one is made just to erase what its extensions stored.
            let host = extensionHosts.removeValue(forKey: id) as? ExtensionHost ?? (testing ? nil
                : ExtensionHost(catalog: ExtensionCatalog(fileURL: nil), filesDirectory: nil, websiteDataStore: .nonPersistent(),
                                storageIdentifier: id, isPrivate: false))
            await host?.removeAllData()
        }
        extensionCatalogs.removeValue(forKey: id)?.removeFile()
        pullRequestFeeds.removeValue(forKey: id)?.stop()
        if let files = extensionFilesDirectory(for: id) { try? FileManager.default.removeItem(at: files) }
        if extensionsProfileID == id { extensionsProfileID = nil }
        if let vault = passwordVaults.removeValue(forKey: id) { vault.removeAll() }
        else { PasswordVault.remove(fileURL: passwordsFile(for: id), key: testing ? nil : vaultKey(for: id)) }
        if passwordsProfileID == id { passwordsProfileID = nil }
        applyingWorkspace = false
        saveAll()
        guard await persistence?.flush() == true else {
            profileError = "The profile change could not be saved. Its website data was kept. \(persistence?.error ?? "")"
            return
        }
        for store in icons { await store.shutdown() }
        try? await history?.removeFile()
        await Task.yield()
        await retryWebsiteDataCleanup()
    }

    func retryWebsiteDataCleanup() async {
        guard persistence?.isAvailable == true, !cleaningWebsiteData else { return }
        cleaningWebsiteData = true
        defer { cleaningWebsiteData = false }
        var attempted = Set<String>()
        // Startup recovery and an interactive deletion can overlap. One worker
        // drains new requests as they arrive; failures wait until next launch.
        while await persistence?.flush() == true {
            let pending = (defaults.stringArray(forKey: "pendingProfileCleanup") ?? []).filter { !attempted.contains($0) }
            guard !pending.isEmpty else { return }
            for value in pending {
                attempted.insert(value)
                guard let id = UUID(uuidString: value), !profiles.contains(where: { $0.id == id }) else { continue }
                do {
                    if !testing {
                        try await WKWebsiteDataStore.remove(forIdentifier: id)
                        try await FaviconStore.removeCache(for: id)
                    }
                    if let file = historyFile(for: id) { try await HistoryStore(fileURL: file).removeFile() }
                    if let file = sitePermissionsFile(for: id) { try? FileManager.default.removeItem(at: file) }
                    if let file = localFilesFile(for: id) { try? FileManager.default.removeItem(at: file) }
                    if let file = extensionsFile(for: id) { try? FileManager.default.removeItem(at: file) }
                    if let files = extensionFilesDirectory(for: id) { try? FileManager.default.removeItem(at: files) }
                    if let file = passwordsFile(for: id), FileManager.default.fileExists(atPath: file.path) {
                        PasswordVault.remove(fileURL: file, key: testing ? nil : vaultKey(for: id))
                    }
                    var remaining = defaults.stringArray(forKey: "pendingProfileCleanup") ?? []
                    remaining.removeAll { $0 == value }
                    defaults.set(remaining, forKey: "pendingProfileCleanup")
                } catch {
                    profileError = "The profile was removed, but its website data could not yet be erased. Early will retry on next launch. \(error.localizedDescription)"
                }
            }
        }
    }

    func closeWindow(_ id: UUID?) {
        guard !isTerminating, let closed = windowModel(id) else { return }
        let profileID = closed.coordinator.profileID
        nativeWindows.removeAll { $0.id == id || $0.window == nil }
        if let id { windows.removeAll { $0.id == id }; windowDidRegister(id) }
        else { primaryWindowIsOpen = false; model = nil }
        closed.onSave = nil
        closed.onOpenWindow = nil
        closed.onOpenSettings = nil
        closed.application = nil
        let snapshot = closed.coordinator.session
        if !closed.isPrivate, snapshot.hasTodayTabs {
            closedWindows.append(ClosedWindow(session: snapshot))
            closedWindows.removeFirst(max(0, closedWindows.count - Self.closedWindowLimit))
        }
        closed.cancelCommandBarQueries()
        closed.closeExtensionWindow()
        closed.webViews.discardAll()
        if closed.isPrivate {
            releasePrivateSessionIfUnused()
            return
        }
        if !visibleModels.contains(where: { $0.coordinator.profileID == profileID }),
           let index = workspace?.sessions.firstIndex(where: { $0.profileID == profileID }) {
            workspace?.sessions[index] = closed.coordinator.session.savedItemsOnly
        }
        saveAll()
    }

    /// ⌘T or ⌘L with no browser window in front (none open, or Settings in
    /// front): the frontmost browser window gets the command bar, or a new
    /// window opens with it.
    @discardableResult
    func presentCommandBar(_ intent: CommandBarIntent) -> Bool {
        guard canOpenWindow else { return false }
        if let front = windowsInOrder.first(where: { $0.window.isVisible })?.model {
            nativeWindow(of: front)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return front.perform(.presentCommandBar(intent))
        }
        // A new window opens with the command bar ready.
        return openNewWindow() != nil
    }

    /// Browser windows from front to back.
    private var windowsInOrder: [(window: NSWindow, model: BrowserWindowModel)] {
        NSApp.orderedWindows.compactMap { window in browserModel(for: window).map { (window, $0) } }
    }

    /// The model of a native browser window: as it registered, or by its name.
    func browserModel(for window: NSWindow?) -> BrowserWindowModel? {
        guard let window else { return nil }
        if let registered = nativeWindows.first(where: { $0.window === window }) {
            guard let id = registered.id else { return primaryWindowIsOpen ? model : nil }
            return windowModel(id)
        }
        guard let identifier = window.identifier?.rawValue else { return nil }
        if identifier == "browser" { return primaryWindowIsOpen ? model : nil }
        guard identifier.hasPrefix("browser."), let id = UUID(uuidString: String(identifier.dropFirst("browser.".count))) else { return nil }
        return windowModel(id)
    }

    // MARK: Links from other apps

    /// Links and web pages from other apps and Finder, which SwiftUI hands to
    /// a window's `onOpenURL` (including the link that launched Early), open
    /// as new Today tabs in the frontmost ordinary window, or in a new window
    /// of the current profile when none is open; never in a private window.
    /// Only web addresses and files.
    func openExternalLinks(_ urls: [URL]) {
        pendingLinks = Array((pendingLinks + urls).prefix(Self.externalLinkLimit))
        deliverExternalLinks()
    }

    private func deliverExternalLinks() {
        guard !pendingLinks.isEmpty, workspace != nil, !isTerminating, !profileOperationInProgress else { return }
        let schemes: Set<String> = testing ? ["http", "https", "file", "early-test"] : ["http", "https", "file"]
        let links = pendingLinks.filter { schemes.contains($0.scheme?.lowercased() ?? "") }.compactMap { try? input.validate($0) }
        pendingLinks = []
        guard !links.isEmpty else { return }
        let front = windowsInOrder.first { !$0.model.isPrivate && ($0.window.isVisible || $0.window.isMiniaturized) }
        // The first window may still be appearing when Early was launched by the link.
        let target = front?.model ?? (primaryWindowIsOpen && model?.isPrivate == false ? model : nil)
        if let target {
            if front?.window.isMiniaturized == true { front?.window.deminiaturize(nil) }
            target.openLocations(links)
            nativeWindow(of: target)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let id = openNewWindow() {
            windowModel(id)?.openLocations(links)
        }
    }

    // MARK: Default browser

    private var browserHandler: DefaultBrowser { defaultBrowser ?? (testing ? .unavailable : .system) }

    func refreshDefaultBrowser() {
        let value = browserHandler.isDefault()
        if isDefaultBrowser != value { isDefaultBrowser = value }
    }

    /// macOS asks the person first; keeping their browser is respected.
    func makeDefaultBrowser() async {
        await browserHandler.makeDefault()
        refreshDefaultBrowser()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if workspace != nil { refreshDefaultBrowser() }
    }

    /// Clicking the Dock icon with no window showing brings back a minimized
    /// browser window, or opens one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, workspace != nil else { return true }
        if let minimized = NSApp.windows.first(where: { $0.isMiniaturized && browserModel(for: $0) != nil }) {
            minimized.deminiaturize(nil)
        } else {
            _ = openNewWindow()
        }
        return false
    }

    func applyAppearance() {
        switch preferences?.appearance ?? .system {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if env["EARLY_TEST_DEFAULTS_SUITE"]?.hasPrefix("local.early.tests.") == true,
               let appearance = env["EARLY_TEST_APPEARANCE"], ["light", "dark"].contains(appearance) {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                return
            }
            #endif
            NSApp.appearance = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        WebViewManager.registerInspectorDefaults()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Every profile's passwords reached the disk, or the person chose to quit
    /// without them. Cancel keeps Early open with them still in memory.
    func passwordsSavedBeforeQuitting() async -> Bool {
        await Self.passwordsSaved(Array(passwordVaults.values), ask: askToQuitWithUnsavedPasswords)
    }

    static func passwordsSaved(_ vaults: [PasswordVault], ask: (String?) -> NSApplication.ModalResponse) async -> Bool {
        while true {
            var unsaved: [PasswordVault] = []
            for vault in vaults {
                if !(await vault.flush()) { unsaved.append(vault) }
            }
            guard let first = unsaved.first else { return true }
            switch ask(first.saveError) {
            case .alertFirstButtonReturn: unsaved.forEach { $0.retrySaving() }
            case .alertSecondButtonReturn: return false
            default: return true
            }
        }
    }

    /// Tests answer for the person.
    @ObservationIgnored var askToQuitWithUnsavedPasswords: (String?) -> NSApplication.ModalResponse = { reason in
        let alert = NSAlert()
        alert.messageText = "Your passwords couldn’t be saved"
        alert.informativeText = "\(reason ?? "They couldn’t be written to disk.") If you quit now, your latest password changes are lost."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let persistence else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        if hasActiveDownloads {
            let count = downloadStores.values.reduce(0) { $0 + $1.activeCount }
            let alert = NSAlert()
            alert.messageText = count == 1 ? "A download is in progress" : "\(count) downloads are in progress"
            alert.informativeText = "Quitting Early cancels \(count == 1 ? "it" : "them")."
            alert.addButton(withTitle: "Continue Downloading")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            downloadStores.values.forEach { $0.cancelAll() }
        }
        isTerminating = true
        saveAll()
        Task { @MainActor in
            var canQuit = await self.passwordsSavedBeforeQuitting()
            if canQuit { canQuit = await persistence.flush() }
            else {
                self.isTerminating = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if !canQuit {
                let alert = NSAlert()
                alert.messageText = "Your session could not be saved"
                alert.informativeText = persistence.error ?? "Session storage is unavailable."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                canQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if canQuit {
                // Stopped transfers cannot resume after quitting; remove their partial files.
                self.downloadStores.values.forEach { $0.cancelAll() }
                self.visibleModels.forEach { $0.webViews.discardAll() }
            }
            else { self.isTerminating = false }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}

/// Published for the menu bar, which SwiftUI rebuilds as this changes. The
/// title reads nothing else, so whenever SwiftUI builds it, it's current.
@MainActor final class FrontWindowState: ObservableObject {
    @Published var showsPage = false
}
