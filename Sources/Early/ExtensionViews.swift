// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Site Controls button's frame, where extension popups point from.
struct SiteControlsFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

// MARK: - A window, as extensions see it

extension BrowserWindowModel: ExtensionTabsOwner {
    var extensionTabIDs: [UUID] { coordinator.tabStore.tabs.filter(\.isOpen).map(\.id) }
    var extensionActiveTabID: UUID? { coordinator.focusedTabID }

    func extensionTabState(_ id: UUID) -> ExtensionTabState? {
        guard let tab = coordinator.tabStore.tab(id: id), tab.isOpen else { return nil }
        let page = webViews.pages[id]
        return ExtensionTabState(url: page?.view.url ?? tab.currentURL, title: tab.displayTitle, isPinned: tab.pinnedURL != nil,
                                 isMuted: page?.isMuted ?? false, isPlayingAudio: page?.isPlayingMedia ?? false,
                                 isLoadingComplete: page.map { !$0.isLoading } ?? true)
    }

    func extensionWebView(_ id: UUID) -> WKWebView? { webViews.existingView(for: id) }
    func extensionActivate(_ id: UUID) { selectTab(id) }
    func extensionClose(_ id: UUID) { closeTab(id) }

    func extensionLoad(_ url: URL, in id: UUID) {
        guard let url = try? input.validate(url), let tab = coordinator.tabStore.tab(id: id), tab.isOpen else { return }
        webViews.load(url, in: tab)
    }

    func extensionReload(_ id: UUID) { webViews.reload(id) }
    func extensionGoBack(_ id: UUID) { webViews.back(id) }
    func extensionGoForward(_ id: UUID) { webViews.forward(id) }
    func extensionSetMuted(_ muted: Bool, _ id: UUID) { _ = webViews.setMuted(muted, for: id) }
    var extensionWindowFrame: CGRect { application?.nativeWindow(of: self)?.frame ?? .zero }

    func extensionFocusWindow() {
        application?.nativeWindow(of: self)?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func extensionCloseWindow() { application?.nativeWindow(of: self)?.performClose(nil) }

    /// Pages get the profile's extensions, which learn about this window.
    @available(macOS 15.4, *)
    func connectExtensions() {
        guard let host = extensionHost as? ExtensionHost else { return }
        webViews.extensionController = host.controller
        let window = ExtensionWindow(owner: self, isPrivate: isPrivate)
        extensionWindow = window
        webViews.extensionMenuItems = { [weak window, weak host] id in
            guard let window, let host, let tab = window.tab(id) else { return [] }
            return host.menuItems(for: tab)
        }
        webViews.extensionCommand = { [weak host] event in host?.performCommand(for: event) ?? false }
        webViews.extensionPageConfiguration = { [weak host] url in host?.pageConfiguration(for: url) }
        webViews.onNeedsNewView = { [weak self] id, url in
            guard let self, let tab = self.coordinator.tabStore.tab(id: id), tab.isOpen else { return }
            self.webViews.load(url, in: tab)
        }
        host.register(window)
    }

    /// Its extension loaded: open tabs showing its pages get a view that works.
    func reloadExtensionPages(from base: URL) {
        let origin = WebViewManager.extensionOrigin(of: base)
        for tab in coordinator.tabStore.tabs where tab.isOpen && webViews.pages[tab.id] != nil
            && WebViewManager.extensionOrigin(of: tab.currentURL) == origin {
            webViews.load(tab.currentURL, in: tab)
        }
    }

    /// Tabs opened, closed or selected since extensions last heard.
    func syncExtensionWindow() {
        if #available(macOS 15.4, *) { (extensionWindow as? ExtensionWindow)?.sync() }
    }

    func extensionTabChanged(_ id: UUID) {
        if #available(macOS 15.4, *) { (extensionWindow as? ExtensionWindow)?.tabChanged(id) }
    }

    func extensionWindowDidFocus() {
        guard #available(macOS 15.4, *), let host = extensionHost as? ExtensionHost,
              let window = extensionWindow as? ExtensionWindow else { return }
        host.focus(window)
    }

    func closeExtensionWindow() {
        if #available(macOS 15.4, *) { (extensionWindow as? ExtensionWindow)?.close() }
        extensionWindow = nil
    }

    /// A tab an extension opened: its own page, or a website.
    @available(macOS 15.4, *)
    @discardableResult
    func openExtensionTab(_ url: URL, active: Bool) -> ExtensionTab? {
        guard let url = try? input.validate(url) else { return nil }
        let id: UUID
        if active {
            if coordinator.commandBar != nil { dismissCommandBar(restoreFocus: false) }
            guard let opened = coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)) else { return nil }
            id = opened
        } else {
            id = coordinator.openBackgroundTab(to: url)
        }
        guard let tab = coordinator.tabStore.tab(id: id) else { return nil }
        webViews.load(url, in: tab)
        if active { contentFocusRequest += 1 }
        save()
        return (extensionWindow as? ExtensionWindow)?.tab(id)
    }

    /// An extension's popup, from the Site Controls button (or the top of
    /// the window when the button is hidden).
    @available(macOS 15.4, *)
    func presentExtensionPopup(_ action: WKWebExtension.Action) -> Bool {
        guard let popover = action.popupPopover, let window = application?.nativeWindow(of: self),
              let content = window.contentView else { return false }
        var anchor = siteControlsFrame ?? CGRect(x: content.bounds.maxX - 60, y: 8, width: 26, height: 26)
        if !content.isFlipped { anchor.origin.y = content.bounds.height - anchor.maxY }
        popover.behavior = .transient
        popover.show(relativeTo: anchor, of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
        return true
    }
}

// MARK: - Changing a profile's extensions

@available(macOS 15.4, *)
extension EarlyAppDelegate {
    /// One choice changes, in the profile's windows and its private windows.
    /// Website access applies in place; turning it on or off restarts it.
    func changeExtension(_ id: UUID, in profile: UUID, restart: Bool, _ body: (inout InstalledExtension) -> Void) async {
        extensionCatalog(for: profile).change(id, body)
        for host in runningExtensionHosts(of: profile) {
            if restart { await host.reapply(id) } else { host.refreshAccess(id) }
        }
    }

    func removeExtension(_ id: UUID, from profile: UUID) async {
        for host in runningExtensionHosts(of: profile) where host.isPrivate { host.unload(id) }
        await (extensionHost(for: profile) as? ExtensionHost)?.remove(id)
    }
}

// MARK: - Settings › Extensions

/// What an extension will be able to do, before it's added.
@MainActor
enum ExtensionAccess {
    private static let uses: [String: String] = [
        "bookmarks": "see and change bookmarks",
        "clipboardRead": "read what you copy",
        "clipboardWrite": "copy to the clipboard",
        "contextMenus": "add items to page menus",
        "cookies": "read and change cookies",
        "declarativeNetRequest": "block or change content on websites",
        "declarativeNetRequestWithHostAccess": "block or change content on websites",
        "downloads": "manage downloads",
        "history": "see your browsing history",
        "nativeMessaging": "talk to its Mac app",
        "notifications": "show notifications",
        "scripting": "run scripts on websites it can reach",
        "tabs": "see your open tabs",
        "webNavigation": "see the pages you visit",
    ]

    static func summary(permissions: Set<String>, allSites: Bool, hosts: [String]) -> String {
        var parts: [String] = []
        if allSites { parts.append("It can read and change every website you visit.") }
        else if !hosts.isEmpty { parts.append("It can read and change \(ListFormatter.localizedString(byJoining: hosts.sorted())).") }
        let uses = Set(permissions.compactMap { Self.uses[$0] }).sorted()
        if !uses.isEmpty { parts.append("It may also \(ListFormatter.localizedString(byJoining: uses)).") }
        return parts.isEmpty ? "It doesn’t ask to read or change websites." : parts.joined(separator: " ")
    }

    @available(macOS 15.4, *)
    static func summary(of webExtension: WKWebExtension) -> String {
        let patterns = webExtension.allRequestedMatchPatterns
        let hosts = Set(patterns.compactMap { $0.host }.filter { !$0.isEmpty && $0 != "*" }).map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
        return summary(permissions: Set(webExtension.requestedPermissions.map(\.rawValue)),
                       allSites: patterns.contains { $0.matchesAllURLs || $0.matchesAllHosts }, hosts: hosts)
    }
}

struct ExtensionsSettingsSection: View {
    @Bindable var application: EarlyAppDelegate

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionsSettingsContent(application: application)
        } else {
            SettingsCard {
                Label("Extensions need macOS 15.4 or later", systemImage: "puzzlepiece.extension").font(.headline)
                Text("Early runs extensions with the same part of macOS that Safari uses, which arrived in macOS 15.4.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsSettingsContent: View {
    /// An extension waiting for the person to confirm adding it.
    struct PendingAdd: Identifiable {
        enum Source { case app(DiscoveredExtension), files(URL) }
        let id = UUID()
        let source: Source
        let name: String
        let summary: String
    }

    @Bindable var application: EarlyAppDelegate
    @State private var host: ExtensionHost?
    @State private var discovered: [DiscoveredExtension] = []
    @State private var expanded: UUID?
    @State private var pending: PendingAdd?
    @State private var removing: InstalledExtension?
    @State private var failure: String?
    @State private var working = false

    private var profileID: UUID? {
        let profiles = application.profiles
        if let id = application.extensionsProfileID, profiles.contains(where: { $0.id == id }) { return id }
        return application.workspace?.activeProfileID ?? profiles.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                Label("Add features to Early", systemImage: "puzzlepiece.extension").font(.callout.weight(.medium))
                Text("Early runs Safari Web Extensions. Each profile has its own, used only in its windows. Private windows use one only when you allow it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if application.profiles.count > 1 { profilePicker }
            if let host, let error = host.catalog.saveError {
                SaveFailureNotice(message: error, identifier: "extensions.retrySave") { host.catalog.retrySaving() }
            }
            if let host, let profileID {
                installed(host, profile: profileID)
                available(host)
            }
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(BrowserExtensions.storeURL) } label: {
                    Label("Get Extensions…", systemImage: "bag")
                }
                .accessibilityIdentifier("extensions.store")
                Button("Install from Folder or ZIP…") { chooseFiles() }
                    .disabled(host == nil || working)
                    .accessibilityIdentifier("extensions.installFiles")
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            Text("Extensions from the App Store come inside a Mac app: install the app, open it once, then add its extension here. Parts that talk to their Mac app work only in Safari.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: profileID) {
            host = profileID.flatMap { application.extensionHost(for: $0) as? ExtensionHost }
            expanded = nil
        }
        .task {
            let folders = BrowserExtensions.applicationFolders
            discovered = await Task.detached { BrowserExtensions.discover(in: folders) }.value
        }
        .alert("Add “\(pending?.name ?? "")”?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { request in
            Button("Add") { add(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("\(request.summary) You can choose which websites it can use after adding it.")
        }
        .alert("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { item in
            Button("Remove", role: .destructive) {
                guard let profileID else { return }
                Task { await application.removeExtension(item.id, from: profileID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.source.isFromApp ? "Its settings and data in this profile are removed. The app it came with stays installed."
                 : "Its files, settings and data in this profile are removed.")
        }
        .alert("The extension couldn’t be added", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private var profilePicker: some View {
        HStack {
            Text("Profile").font(.body.weight(.medium))
            Spacer()
            Picker("Profile", selection: Binding(get: { profileID }, set: { application.extensionsProfileID = $0 })) {
                ForEach(application.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("extensions.profile")
        }
    }

    @ViewBuilder private func installed(_ host: ExtensionHost, profile: UUID) -> some View {
        let items = host.catalog.extensions
        if items.isEmpty {
            SettingsCard {
                Text("No extensions in this profile").font(.headline)
                Text(discovered.isEmpty ? "Get one from the App Store, or install one from a folder or ZIP file."
                     : "Add one that came with an app on your Mac, below.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 8) {
                ForEach(items) { item in row(item, host: host, profile: profile) }
            }
        }
    }

    @ViewBuilder private func available(_ host: ExtensionHost) -> some View {
        let added = Set(host.catalog.extensions.compactMap { item -> String? in
            if case .app(_, let identifier) = item.source { return identifier }
            return nil
        })
        let offered = discovered.filter { !added.contains($0.bundleIdentifier) }
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FROM YOUR MAC APPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(offered) { found in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: found.appURL.path))
                            .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                        Text(found.appName).font(.body.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Add…") { prepare(.app(found)) }
                            .disabled(working)
                            .accessibilityIdentifier("extensions.add.\(found.bundleIdentifier)")
                    }
                    .padding(14)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.07)) }
                }
            }
        }
    }

    private func row(_ item: InstalledExtension, host: ExtensionHost, profile: UUID) -> some View {
        let isExpanded = expanded == item.id
        let context = host.context(item.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded = isExpanded ? nil : item.id }
                } label: {
                    HStack(spacing: 12) {
                        ExtensionIcon(image: context?.webExtension.icon(for: CGSize(width: 32, height: 32)), size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(subtitle(item, host: host)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus()
                .accessibilityLabel(item.name)
                .accessibilityIdentifier("extensions.row.\(item.id)")
                Toggle("Turn On", isOn: Binding(get: { item.isEnabled }, set: { on in
                    Task { await application.changeExtension(item.id, in: profile, restart: true) { $0.isEnabled = on } }
                }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Turn On \(item.name)")
                .accessibilityIdentifier("extensions.enabled.\(item.id)")
            }
            if isExpanded { details(item, context: context, host: host, profile: profile) }
        }
        .padding(14)
        .background(.primary.opacity(isExpanded ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(isExpanded ? 0.14 : 0.07)) }
    }

    private func subtitle(_ item: InstalledExtension, host: ExtensionHost) -> String {
        if let problem = host.problems[item.id] { return problem }
        let version = item.version.isEmpty ? "" : "Version \(item.version) · "
        guard item.isEnabled else { return version + "Off" }
        return version + item.siteAccess.title
    }

    private func details(_ item: InstalledExtension, context: WKWebExtensionContext?, host: ExtensionHost, profile: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if let description = context?.webExtension.displayDescription, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Website access").font(.callout)
                Spacer()
                Picker("Website access", selection: Binding(get: { item.siteAccess }, set: { access in
                    Task { await application.changeExtension(item.id, in: profile, restart: false) { $0.siteAccess = access } }
                })) {
                    ForEach(ExtensionSiteAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("extensions.access.\(item.id)")
            }
            if item.siteAccess == .whenClicked {
                Text(item.allowedSites.isEmpty ? "It works on a page after you click it in Site Controls."
                     : "Also allowed on these websites:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(item.allowedSites, id: \.self) { site in
                    HStack {
                        Text(site).font(.callout)
                        Spacer()
                        Button {
                            Task { await application.changeExtension(item.id, in: profile, restart: false) {
                                $0.allowedSites.removeAll { $0 == site }
                            } }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop Allowing on \(site)")
                        .accessibilityLabel("Stop Allowing on \(site)")
                    }
                }
            }
            Toggle("Allow in private windows", isOn: Binding(get: { item.allowsPrivateWindows }, set: { allowed in
                Task { await application.changeExtension(item.id, in: profile, restart: true) { $0.allowsPrivateWindows = allowed } }
            }))
            .accessibilityIdentifier("extensions.private.\(item.id)")
            Toggle("Allow access to local files", isOn: Binding(get: { item.allowsLocalFiles }, set: { allowed in
                Task { await application.changeExtension(item.id, in: profile, restart: false) { $0.allowsLocalFiles = allowed } }
            }))
            .help("Lets it open files on this Mac in tabs and read local pages")
            .accessibilityIdentifier("extensions.localFiles.\(item.id)")
            if let context, ExtensionHost.needsItsApp(context) {
                Label("Parts of this extension that talk to its Mac app work only in Safari.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if let options = context?.optionsPageURL {
                    Button("Options…") { application.openExtensionPage(options, profile: profile) }
                        .accessibilityIdentifier("extensions.options.\(item.id)")
                }
                Button("Remove…", role: .destructive) { removing = item }
                    .accessibilityIdentifier("extensions.remove.\(item.id)")
                Spacer()
                Text(item.source.isFromApp ? "From a Mac app" : "Installed from files").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Install"
        panel.message = "Choose an extension’s folder (with its manifest.json) or ZIP file."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            prepare(.files(url))
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    /// Reads the extension first, to say what it can do.
    private func prepare(_ source: PendingAdd.Source) {
        working = true
        Task {
            defer { working = false }
            do {
                let webExtension: WKWebExtension
                let fallback: String
                switch source {
                case .app(let found):
                    guard let bundle = Bundle(url: found.extensionURL) else { throw ExtensionHost.ExtensionError.missing }
                    webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                    fallback = found.appName
                case .files(let url):
                    webExtension = try await WKWebExtension(resourceBaseURL: url)
                    fallback = url.deletingPathExtension().lastPathComponent
                }
                pending = PendingAdd(source: source, name: webExtension.displayName ?? fallback,
                                     summary: ExtensionAccess.summary(of: webExtension))
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func add(_ request: PendingAdd) {
        guard let host else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let item: InstalledExtension
                switch request.source {
                case .app(let found): item = try await host.add(found)
                case .files(let url): item = try await host.add(files: url)
                }
                expanded = item.id
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// An extension's own icon, or a puzzle piece until it has one.
struct ExtensionIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Site Controls

/// The window's extensions with a button: click one to use it on this page.
@available(macOS 15.4, *)
struct SiteControlsExtensions: View {
    @Bindable var model: BrowserWindowModel
    let host: ExtensionHost
    let tabID: UUID
    let tint: Color
    let dismiss: () -> Void

    static func accessValue(_ item: InstalledExtension, site: String?) -> String {
        if item.siteAccess == .allSites { return "Allowed on all websites" }
        if let site, item.allowedSites.contains(site) { return "Allowed on this website" }
        return "Click to use on this page"
    }

    var body: some View {
        _ = host.actionRevision
        let items = host.actionExtensions
        let tab = (model.extensionWindow as? ExtensionWindow)?.tab(tabID)
        let site = model.currentPageURL.flatMap(ExtensionCatalog.site(of:))
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extensions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    if let error = host.catalog.saveError {
                        SaveFailureNotice(message: error, compact: true, identifier: "siteControls.retrySaveExtensions") {
                            host.catalog.retrySaving()
                        }
                    }
                    ForEach(items) { item in
                        let action = host.context(item.id)?.action(for: tab)
                        row(item, action: action, tab: tab, site: site)
                    }
                }
            }
        }
    }

    private func row(_ item: InstalledExtension, action: WKWebExtension.Action?, tab: ExtensionTab?, site: String?) -> some View {
        let badge = action?.badgeText ?? ""
        return HStack(spacing: 10) {
            Button {
                dismiss()
                // After the panel closes, so the extension's popup can show.
                DispatchQueue.main.async { host.performAction(item.id, in: tab) }
            } label: {
                HStack(spacing: 10) {
                    ExtensionIcon(image: action?.icon(for: CGSize(width: 20, height: 20)), size: 20)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if !badge.isEmpty {
                                Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                                    .background(tint, in: Capsule())
                                    .offset(x: 4, y: -3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action?.label.isEmpty == false ? action!.label : item.name)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(Self.accessValue(item, site: site)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .browserKeyboardFocus(cornerRadius: 8)
            .disabled(action?.isEnabled == false)
            .accessibilityLabel(item.name)
            .accessibilityValue(badge.isEmpty ? Self.accessValue(item, site: site) : "\(badge), \(Self.accessValue(item, site: site))")
            .accessibilityIdentifier("siteControls.extension.\(item.id)")
            Menu {
                if let site, item.siteAccess == .whenClicked, let profile = model.application.flatMap({ $0.extensionsProfileID(of: model) }) {
                    let allowed = item.allowedSites.contains(site)
                    Button(allowed ? "Stop Allowing on \(site)" : "Always Allow on \(site)") {
                        Task { await model.application?.changeExtension(item.id, in: profile, restart: false) { saved in
                            saved.allowedSites.removeAll { $0 == site }
                            if !allowed { saved.allowedSites.append(site) }
                        } }
                    }
                }
                if let options = host.context(item.id)?.optionsPageURL {
                    Button("Options…") {
                        dismiss()
                        model.openExtensionTab(options, active: true)
                    }
                }
                Divider()
                Button("Manage Extensions…") {
                    dismiss()
                    model.application?.showExtensions(profileID: model.application?.extensionsProfileID(of: model))
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: Circle()).contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(item.name) Options")
            .accessibilityLabel("\(item.name) Options")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - The Extensions menu

/// The menu bar's Extensions menu: each extension of the focused window, and
/// where to manage or find more.
struct ExtensionsMenuItems: View {
    let application: EarlyAppDelegate
    let model: BrowserWindowModel?

    var body: some View {
        Button("Manage Extensions…") {
            application.showExtensions(profileID: model.flatMap { application.extensionsProfileID(of: $0) })
        }
        .disabled(application.workspace == nil)
        if #available(macOS 15.4, *) {
            if let model, let host = model.extensionHost as? ExtensionHost, !host.actionExtensions.isEmpty {
                Divider()
                ExtensionsMenuList(application: application, model: model, host: host)
            }
        }
        Divider()
        Button("Get Extensions…") { NSWorkspace.shared.open(BrowserExtensions.storeURL) }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsMenuList: View {
    let application: EarlyAppDelegate
    let model: BrowserWindowModel
    let host: ExtensionHost

    var body: some View {
        _ = host.actionRevision
        let tab = model.coordinator.focusedTabID.flatMap { (model.extensionWindow as? ExtensionWindow)?.tab($0) }
        let site = model.currentPageURL.flatMap(ExtensionCatalog.site(of:))
        return ForEach(host.actionExtensions) { item in
            let context = host.context(item.id)
            Menu {
                Button("Use on This Page") { host.performAction(item.id, in: tab) }
                    .disabled(tab == nil || context?.action(for: tab)?.isEnabled == false)
                if let site, item.siteAccess == .whenClicked, let profile = application.extensionsProfileID(of: model) {
                    let allowed = item.allowedSites.contains(site)
                    Button(allowed ? "Stop Allowing on \(site)" : "Always Allow on \(site)") {
                        Task { await application.changeExtension(item.id, in: profile, restart: false) { saved in
                            saved.allowedSites.removeAll { $0 == site }
                            if !allowed { saved.allowedSites.append(site) }
                        } }
                    }
                }
                if let options = context?.optionsPageURL {
                    Button("Options…") { model.openExtensionTab(options, active: true) }
                }
            } label: {
                // Its button's icon on this page, as Site Controls shows it.
                Label {
                    Text(item.name)
                } icon: {
                    if let icon = context?.action(for: tab)?.icon(for: BrowserCommands.menuIconSize)
                        ?? context?.webExtension.icon(for: BrowserCommands.menuIconSize) {
                        Image(nsImage: BrowserCommands.menuIcon(icon))
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }
}
