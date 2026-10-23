// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import WebKit

/// A Safari Web Extension inside an installed Mac app, not yet added.
public struct DiscoveredExtension: Equatable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let extensionURL: URL
    public let appName: String
    public let appURL: URL
}

/// Web Extensions through WebKit's own support (macOS 15.4 and later), the
/// same one Safari uses.
public enum BrowserExtensions {
    public static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// Mac apps' Safari Web Extensions get Safari's scheme, as they expect;
    /// folder and ZIP installs keep WebKit's own.
    public static let appScheme = "safari-web-extension"
    public static let fileScheme = "webkit-extension"
    static let safariExtensionPoint = "com.apple.Safari.web-extension"
    /// Where "Get Extensions…" goes: the App Store's Safari extensions.
    public static let storeURL = URL(string: "macappstore://apps.apple.com/story/id1377753262")!

    /// Safari Web Extensions in the apps in these folders and their direct
    /// subfolders (such as /Applications/Utilities).
    public nonisolated static func discover(in folders: [URL]) -> [DiscoveredExtension] {
        let files = FileManager.default
        var apps: [URL] = []
        for folder in folders {
            let entries = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                if entry.pathExtension == "app" { apps.append(entry); continue }
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                apps += ((try? files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
            }
        }
        var found: [DiscoveredExtension] = []
        for app in apps {
            let plugins = app.appending(path: "Contents/PlugIns")
            for plugin in (try? files.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [] where plugin.pathExtension == "appex" {
                guard let info = NSDictionary(contentsOf: plugin.appending(path: "Contents/Info.plist")) as? [String: Any],
                      let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                      point == safariExtensionPoint, let identifier = info["CFBundleIdentifier"] as? String,
                      files.fileExists(atPath: plugin.appending(path: "Contents/Resources/manifest.json").path) else { continue }
                found.append(DiscoveredExtension(bundleIdentifier: identifier, extensionURL: plugin,
                                                 appName: files.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                                                 appURL: app))
            }
        }
        return found.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    public static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
    }
}

/// What a window tells extensions about its tabs, and does for them.
@MainActor
public protocol ExtensionTabsOwner: AnyObject {
    /// Open tabs in sidebar order.
    var extensionTabIDs: [UUID] { get }
    var extensionActiveTabID: UUID? { get }
    func extensionTabState(_ id: UUID) -> ExtensionTabState?
    func extensionWebView(_ id: UUID) -> WKWebView?
    func extensionActivate(_ id: UUID)
    func extensionClose(_ id: UUID)
    func extensionLoad(_ url: URL, in id: UUID)
    func extensionReload(_ id: UUID)
    func extensionGoBack(_ id: UUID)
    func extensionGoForward(_ id: UUID)
    func extensionSetMuted(_ muted: Bool, _ id: UUID)
    var extensionWindowFrame: CGRect { get }
    func extensionFocusWindow()
    func extensionCloseWindow()
}

public struct ExtensionTabState: Equatable, Sendable {
    public var url: URL?
    public var title: String?
    public var isPinned: Bool
    public var isMuted: Bool
    public var isPlayingAudio: Bool
    public var isLoadingComplete: Bool

    public init(url: URL?, title: String?, isPinned: Bool, isMuted: Bool, isPlayingAudio: Bool, isLoadingComplete: Bool) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isPlayingAudio = isPlayingAudio
        self.isLoadingComplete = isLoadingComplete
    }
}

/// A profile's extensions at work: one WebKit extension controller, using
/// the profile's own website data store (pages with another store get no
/// extensions). Private windows have a host of their own.
@available(macOS 15.4, *)
@MainActor @Observable
public final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    public let catalog: ExtensionCatalog
    @ObservationIgnored public let controller: WKWebExtensionController
    @ObservationIgnored let filesDirectory: URL?
    public let isPrivate: Bool
    public private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    /// Why an extension couldn't be turned on.
    public private(set) var problems: [UUID: String] = [:]
    /// Bumped when an extension's icon, badge or title changes.
    public private(set) var actionRevision = 0
    @ObservationIgnored private let windows = NSHashTable<ExtensionWindow>.weakObjects()
    @ObservationIgnored public private(set) weak var focusedWindow: ExtensionWindow?
    /// Opens a tab for an extension; the app decides where.
    @ObservationIgnored public var openTab: ((URL, ExtensionWindow?, _ active: Bool) -> ExtensionTab?)?
    @ObservationIgnored public var openWindow: ((URL?) -> ExtensionWindow?)?
    /// Shows an extension's popup; false when it can't be shown now.
    @ObservationIgnored public var presentPopup: ((WKWebExtension.Action) -> Bool)?
    /// An extension loaded (or loaded again): tabs showing its pages reload.
    @ObservationIgnored public var onLoad: ((_ baseURL: URL) -> Void)?
    /// Asks the person to allow something; tests answer it.
    @ObservationIgnored public var askForAccess: ((_ extensionName: String, _ request: String) async -> Bool)?

    public init(catalog: ExtensionCatalog, filesDirectory: URL?, websiteDataStore: WKWebsiteDataStore,
                storageIdentifier: UUID?, isPrivate: Bool) {
        Self.registerSchemes()
        self.catalog = catalog
        self.filesDirectory = filesDirectory
        self.isPrivate = isPrivate
        let configuration = storageIdentifier.map { WKWebExtensionController.Configuration(identifier: $0) } ?? .nonPersistent()
        configuration.defaultWebsiteDataStore = websiteDataStore
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    private static var schemesRegistered = false
    static func registerSchemes() {
        guard !schemesRegistered else { return }
        schemesRegistered = true
        WKWebExtension.MatchPattern.registerCustomURLScheme(BrowserExtensions.appScheme)
    }

    // MARK: Loading

    /// Every extension that's on (in private windows, those allowed there).
    public func loadEnabled() async {
        for item in catalog.extensions where item.isEnabled && (!isPrivate || item.allowsPrivateWindows) { await load(item.id) }
    }

    @discardableResult
    public func load(_ id: UUID) async -> Bool {
        guard contexts[id] == nil, let item = catalog.installed(id) else { return contexts[id] != nil }
        do {
            let webExtension = try await Self.webExtension(for: item, filesDirectory: filesDirectory)
            guard catalog.installed(id)?.isEnabled == true, contexts[id] == nil else { return false }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = item.id.uuidString
            let scheme = item.source.isFromApp ? BrowserExtensions.appScheme : BrowserExtensions.fileScheme
            context.baseURL = URL(string: "\(scheme)://\(item.id.uuidString.lowercased())/")!
            context.hasAccessToPrivateData = item.allowsPrivateWindows
            applyPermissions(item, to: context)
            try controller.load(context)
            // Some extensions start working when a window gains focus.
            if let focusedWindow { context.didFocusWindow(focusedWindow) }
            contexts[id] = context
            problems[id] = nil
            catalog.change(id) { saved in
                saved.name = webExtension.displayName ?? saved.name
                saved.version = webExtension.displayVersion ?? webExtension.version ?? saved.version
            }
            onLoad?(context.baseURL)
            return true
        } catch {
            problems[id] = error.localizedDescription
            return false
        }
    }

    static func webExtension(for item: InstalledExtension, filesDirectory: URL?) async throws -> WKWebExtension {
        switch item.source {
        case .app(let path, _):
            guard let bundle = Bundle(url: URL(fileURLWithPath: path)) else { throw ExtensionError.missing }
            return try await WKWebExtension(appExtensionBundle: bundle)
        case .files(let folderName):
            guard let filesDirectory else { throw ExtensionError.missing }
            return try await WKWebExtension(resourceBaseURL: filesDirectory.appending(path: folderName, directoryHint: .isDirectory))
        }
    }

    public enum ExtensionError: LocalizedError {
        case missing, alreadyAdded, windowPrivacyMismatch
        public var errorDescription: String? {
            switch self {
            case .missing: "Its files are missing. If it came with an app, the app may have moved or been deleted."
            case .alreadyAdded: "This extension is already added."
            case .windowPrivacyMismatch: "Extensions cannot create a window in a different privacy mode. Open the appropriate window in Early first."
            }
        }
    }

    /// API permissions it asked for, and website access as chosen.
    func applyPermissions(_ item: InstalledExtension, to context: WKWebExtensionContext) {
        let webExtension = context.webExtension
        for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for name in item.grantedPermissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
        for pattern in webExtension.allRequestedMatchPatterns {
            // Unknown, not denied: a click can still grant a page (activeTab).
            context.setPermissionStatus(item.siteAccess == .allSites ? .grantedExplicitly : .unknown, for: pattern)
        }
        for site in item.allowedSites {
            guard let pattern = try? WKWebExtension.MatchPattern(string: "*://\(site)/*") else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// Turns an extension off in this host; the others keep their rules.
    public func unload(_ id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    /// Every extension stops, as when its private session ends.
    public func unloadAll() {
        for id in Array(contexts.keys) { unload(id) }
    }

    /// Website access changed: the running extension gets it without restarting.
    public func refreshAccess(_ id: UUID) {
        guard let item = catalog.installed(id), let context = contexts[id] else { return }
        for pattern in context.grantedPermissionMatchPatterns.keys { context.setPermissionStatus(.unknown, for: pattern) }
        applyPermissions(item, to: context)
    }

    /// Turning it on or off, or allowing it in private windows, takes effect.
    public func reapply(_ id: UUID) async {
        guard let item = catalog.installed(id) else { return }
        let wanted = item.isEnabled && (!isPrivate || item.allowsPrivateWindows)
        if contexts[id] != nil { unload(id) }
        if wanted { await load(id) }
    }

    // MARK: Adding and removing

    /// A Mac app's Safari Web Extension, loaded from the app in place.
    public func add(_ discovered: DiscoveredExtension) async throws -> InstalledExtension {
        let source = ExtensionSource.app(extensionPath: discovered.extensionURL.path, bundleIdentifier: discovered.bundleIdentifier)
        if catalog.installed(source: source) != nil { throw ExtensionError.alreadyAdded }
        guard let bundle = Bundle(url: discovered.extensionURL) else { throw ExtensionError.missing }
        let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
        let item = InstalledExtension(source: source, name: webExtension.displayName ?? discovered.appName,
                                      version: webExtension.displayVersion ?? webExtension.version ?? "")
        catalog.add(item)
        await load(item.id)
        return item
    }

    /// A folder or ZIP the person chose: checked, then copied into Early's
    /// storage so it keeps working if the original moves.
    public func add(files url: URL) async throws -> InstalledExtension {
        guard let filesDirectory else { throw ExtensionError.missing }
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let id = UUID()
        let folderName = id.uuidString
        let destination = filesDirectory.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try FileManager.default.copyItem(at: url, to: destination)
        } else {
            // A ZIP stays a ZIP; WebKit reads it directly.
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        let item = InstalledExtension(id: id, source: .files(folderName: folderName),
                                      name: webExtension.displayName ?? url.deletingPathExtension().lastPathComponent,
                                      version: webExtension.displayVersion ?? webExtension.version ?? "")
        catalog.add(item)
        await load(item.id)
        return item
    }

    /// Removes it from the profile, with its data and copied files.
    public func remove(_ id: UUID) async {
        guard let item = catalog.installed(id) else { return }
        unload(id)
        let types = Set<WKWebExtension.DataType>([.local, .session, .synchronized])
        let own = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == item.id.uuidString }
        if !own.isEmpty { await controller.removeData(ofTypes: types, from: own) }
        if case .files(let folderName) = item.source, let filesDirectory {
            try? FileManager.default.removeItem(at: filesDirectory.appending(path: folderName, directoryHint: .isDirectory))
        }
        catalog.remove(id)
    }

    // MARK: For the interface

    public func context(_ id: UUID) -> WKWebExtensionContext? { contexts[id] }

    /// The configuration a tab's view needs to show one of an extension's own
    /// pages; WebKit refuses them in any other view (NSURLError -1008).
    public func pageConfiguration(for url: URL) -> WKWebViewConfiguration? {
        let origin = WebViewManager.extensionOrigin(of: url)
        return contexts.values.first { WebViewManager.extensionOrigin(of: $0.baseURL) == origin }?.webViewConfiguration
    }

    /// Loaded extensions with a button, in the order they were added.
    public var actionExtensions: [InstalledExtension] {
        catalog.extensions.filter { contexts[$0.id] != nil }
    }

    /// Runs an extension's button on a tab: its popup, or its own action.
    public func performAction(_ id: UUID, in tab: ExtensionTab?) {
        guard let context = contexts[id] else { return }
        if let tab { context.userGesturePerformed(in: tab) }
        context.performAction(for: tab)
    }

    /// Allows an extension on one website, or takes that back.
    public func setAllowed(_ allowed: Bool, site: String, for id: UUID) async {
        catalog.change(id) { item in
            item.allowedSites.removeAll { $0 == site }
            if allowed { item.allowedSites.append(site) }
        }
        refreshAccess(id)
    }

    /// What every extension stored, for deleting the profile.
    public func removeAllData() async {
        unloadAll()
        let types = Set<WKWebExtension.DataType>([.local, .session, .synchronized])
        let records = await controller.dataRecords(ofTypes: types)
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
    }

    /// Items extensions add to a page's menu.
    public func menuItems(for tab: ExtensionTab) -> [NSMenuItem] {
        catalog.extensions.compactMap { contexts[$0.id] }.flatMap { $0.menuItems(for: tab) }
    }

    /// A keyboard shortcut an extension registered.
    public func performCommand(for event: NSEvent) -> Bool {
        contexts.values.contains { $0.performCommand(for: event) }
    }

    /// The extension asks for its Mac app, which only Safari can reach.
    public static func needsItsApp(_ context: WKWebExtensionContext) -> Bool {
        context.webExtension.requestedPermissions.contains(WKWebExtension.Permission(rawValue: "nativeMessaging"))
    }

    // MARK: Windows

    public func register(_ window: ExtensionWindow) {
        guard !windows.contains(window) else { return }
        windows.add(window)
        window.host = self
        controller.didOpenWindow(window)
        window.sync()
    }

    public func focus(_ window: ExtensionWindow?) {
        focusedWindow = window
        controller.didFocusWindow(window)
    }

    func closed(_ window: ExtensionWindow) {
        windows.remove(window)
        if focusedWindow === window { focusedWindow = nil }
        controller.didCloseWindow(window)
    }

    // MARK: WKWebExtensionControllerDelegate

    public func webExtensionController(_ controller: WKWebExtensionController,
                                       openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows.allObjects
    }

    public func webExtensionController(_ controller: WKWebExtensionController,
                                       focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                       for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        let url = configuration.url ?? extensionContext.baseURL
        return openTab?(url, (configuration.window as? ExtensionWindow) ?? focusedWindow, configuration.shouldBeActive)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                       for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // Each host owns one regular or private session. Never silently replace
        // the requested mode with the host's mode, or cross their data stores.
        guard configuration.shouldBePrivate == isPrivate else { throw ExtensionError.windowPrivacyMismatch }
        return openWindow?(configuration.tabURLs.first)
    }

    public func webExtensionController(_ controller: WKWebExtensionController,
                                       openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        _ = openTab?(url, focusedWindow, true)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                       in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext)
        async -> (Set<WKWebExtension.Permission>, Date?) {
        guard let id = id(of: extensionContext) else { return ([], nil) }
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        guard await askForAccess?(name(of: extensionContext), "use more of Early: \(names)") == true else { return ([], nil) }
        catalog.change(id) { item in item.grantedPermissions = Array(Set(item.grantedPermissions).union(permissions.map(\.rawValue))).sorted() }
        return (permissions, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                       in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let sites = Set(urls.compactMap(ExtensionCatalog.site(of:)))
        guard let id = id(of: extensionContext), !sites.isEmpty,
              await askForAccess?(name(of: extensionContext), "read and change \(sites.sorted().joined(separator: ", "))") == true
        else { return ([], nil) }
        catalog.change(id) { item in item.allowedSites = Array(Set(item.allowedSites).union(sites)).sorted() }
        return (urls, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                       in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext)
        async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllURLs || $0.matchesAllHosts }
        let hosts = matchPatterns.compactMap(\.host).filter { !$0.isEmpty && $0 != "*" }.sorted()
        guard let id = id(of: extensionContext),
              await askForAccess?(name(of: extensionContext),
                                  all ? "read and change every website" : "read and change \(hosts.joined(separator: ", "))") == true
        else { return ([], nil) }
        catalog.change(id) { item in
            if all { item.siteAccess = .allSites } else { item.allowedSites = Array(Set(item.allowedSites).union(hosts)).sorted() }
        }
        return (matchPatterns, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                       forExtensionContext context: WKWebExtensionContext) {
        actionRevision += 1
    }

    public func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                       for context: WKWebExtensionContext) async throws {
        guard presentPopup?(action) == true else { throw ExtensionError.missing }
    }

    private func id(of context: WKWebExtensionContext) -> UUID? { UUID(uuidString: context.uniqueIdentifier) }

    private func name(of context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? id(of: context).flatMap { catalog.installed($0)?.name } ?? "An extension"
    }
}

/// One browser window, as extensions see it. Its tabs are kept as stable
/// objects, since extensions tell them apart by identity.
@available(macOS 15.4, *)
@MainActor
public final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    public weak var owner: ExtensionTabsOwner?
    public let isPrivate: Bool
    weak var host: ExtensionHost?
    private var tabs: [UUID: ExtensionTab] = [:]
    private var order: [UUID] = []
    private var active: UUID?

    public init(owner: ExtensionTabsOwner, isPrivate: Bool) {
        self.owner = owner
        self.isPrivate = isPrivate
    }

    public func tab(_ id: UUID) -> ExtensionTab? { tabs[id] }

    public var activeTab: ExtensionTab? { active.flatMap { tabs[$0] } }

    /// Reports opened, closed and selected tabs since the last call.
    public func sync() {
        guard let owner, let controller = host?.controller else { return }
        let ids = owner.extensionTabIDs
        let current = Set(ids)
        for id in order where !current.contains(id) {
            if let tab = tabs.removeValue(forKey: id) { controller.didCloseTab(tab, windowIsClosing: false) }
        }
        for id in ids where tabs[id] == nil {
            let tab = ExtensionTab(id: id, window: self)
            tabs[id] = tab
            controller.didOpenTab(tab)
        }
        order = ids
        let newActive = owner.extensionActiveTabID.flatMap { tabs[$0] != nil ? $0 : nil }
        if newActive != active {
            let previous = active.flatMap { tabs[$0] }
            active = newActive
            if let tab = newActive.flatMap({ tabs[$0] }) { controller.didActivateTab(tab, previousActiveTab: previous) }
        }
    }

    /// A tab's address, title or loading changed.
    public func tabChanged(_ id: UUID) {
        guard let tab = tabs[id] else { return }
        host?.controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    /// The window is closing: its tabs and itself go.
    public func close() {
        guard let host else { return }
        for id in order { if let tab = tabs[id] { host.controller.didCloseTab(tab, windowIsClosing: true) } }
        tabs.removeAll()
        order.removeAll()
        active = nil
        host.closed(self)
        self.host = nil
    }

    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { order.compactMap { tabs[$0] } }
    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    public func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }
    public func frame(for context: WKWebExtensionContext) -> CGRect { owner?.extensionWindowFrame ?? .zero }
    public func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .zero }

    public func focus(for context: WKWebExtensionContext) async throws { owner?.extensionFocusWindow() }
    public func close(for context: WKWebExtensionContext) async throws { owner?.extensionCloseWindow() }

    func index(of id: UUID) -> Int { order.firstIndex(of: id) ?? 0 }
}

/// One tab, as extensions see it.
@available(macOS 15.4, *)
@MainActor
public final class ExtensionTab: NSObject, WKWebExtensionTab {
    public let id: UUID
    weak var window: ExtensionWindow?

    init(id: UUID, window: ExtensionWindow) {
        self.id = id
        self.window = window
    }

    private var owner: ExtensionTabsOwner? { window?.owner }
    private var state: ExtensionTabState? { owner?.extensionTabState(id) }

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }
    public func indexInWindow(for context: WKWebExtensionContext) -> Int { window?.index(of: id) ?? 0 }
    public func webView(for context: WKWebExtensionContext) -> WKWebView? { owner?.extensionWebView(id) }
    public func title(for context: WKWebExtensionContext) -> String? { state?.title }
    public func url(for context: WKWebExtensionContext) -> URL? { state?.url }
    public func isPinned(for context: WKWebExtensionContext) -> Bool { state?.isPinned ?? false }
    public func isMuted(for context: WKWebExtensionContext) -> Bool { state?.isMuted ?? false }
    public func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { state?.isPlayingAudio ?? false }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { state?.isLoadingComplete ?? true }
    public func isSelected(for context: WKWebExtensionContext) -> Bool { window?.activeTab === self }
    public func size(for context: WKWebExtensionContext) -> CGSize { owner?.extensionWebView(id)?.bounds.size ?? .zero }
    public func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(owner?.extensionWebView(id)?.pageZoom ?? 1) }
    /// When You Click It: clicking the extension's button lets it act on this page.
    public func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    public func activate(for context: WKWebExtensionContext) async throws { owner?.extensionActivate(id) }
    public func close(for context: WKWebExtensionContext) async throws { owner?.extensionClose(id) }
    public func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { owner?.extensionLoad(url, in: id) }
    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { owner?.extensionReload(id) }
    public func goBack(for context: WKWebExtensionContext) async throws { owner?.extensionGoBack(id) }
    public func goForward(for context: WKWebExtensionContext) async throws { owner?.extensionGoForward(id) }
    public func setMuted(_ muted: Bool, for context: WKWebExtensionContext) async throws { owner?.extensionSetMuted(muted, id) }
}
