// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
    case appearance = "General", profiles = "Profiles", passwords = "Passwords", privacy = "Privacy", extensions = "Extensions"
    case sidebar = "Sidebar", search = "Search", shortcuts = "Shortcuts", sessions = "Sessions"
    var id: Self { self }
    var key: String {
        switch self {
        case .profiles: "profiles"; case .appearance: "appearance"; case .passwords: "passwords"; case .extensions: "extensions"
        case .privacy: "privacy"; case .shortcuts: "shortcuts"
        case .sidebar: "sidebar"
        case .search: "search"; case .sessions: "sessions"
        }
    }
    var symbol: String {
        switch self {
        case .profiles: "person.crop.circle"
        case .passwords: "key"
        case .extensions: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        case .shortcuts: "keyboard"
        case .appearance: "gearshape"
        case .sidebar: "sidebar.left"
        case .search: "magnifyingglass"
        case .sessions: "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .profiles: "A little separation for the different parts of your day."
        case .passwords: "Saved on this Mac, filled in when you sign in."
        case .extensions: "Add features to Early, one profile at a time."
        case .privacy: "Choose what websites can use and keep."
        case .shortcuts: "Make Early’s commands your own."
        case .appearance: "Make Early feel at home."
        case .sidebar: "Your tabs, organized your way."
        case .search: "Choose what happens as you type."
        case .sessions: "Pick up where you left off, here or on another Mac."
        }
    }
}

struct BrowserSettingsView: View {
    private static let navigationWidth: CGFloat = 190

    @Bindable var application: EarlyAppDelegate
    @Bindable var preferences: BrowserPreferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var profileEditor: ProfileEditorRequest?
    @State private var deletingProfile: BrowserProfile?
    @State private var selectedProfileID: UUID?
    @State private var sessionMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(application.settingsSection.rawValue).font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(application.settingsSection.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                    if application.workspace == nil { ProgressView("Loading your settings…") }
                    else { sectionContent }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 570, alignment: .leading)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("settings.content")
        }
        .frame(minWidth: 760, minHeight: 560)
        .background {
            // Extend one continuous surface behind the native title bar. Only
            // the decoration ignores the safe area; controls stay below it.
            HStack(spacing: 0) {
                Group {
                    if reduceTransparency || contrast == .increased { Color(nsColor: .controlBackgroundColor) }
                    else { Rectangle().fill(.regularMaterial) }
                }
                .frame(width: Self.navigationWidth)
                Color(nsColor: .windowBackgroundColor)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(BrowserSettingsWindowAppearance())
        // Scope this ID to a real group. On macOS a bare container ID replaces
        // the navigation buttons' IDs instead of identifying the container.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settings.window")
        .browserReducedMotion()
        .onAppear { application.presentWindow = { id in openWindow(id: "browser", value: id) } }
        .sheet(item: $profileEditor) { request in
            ProfileEditorSheet(application: application, request: request) { id in
                selectedProfileID = id
                profileEditor = nil
            }
        }
        .alert("Delete \(deletingProfile?.name ?? "profile")?", isPresented: Binding(
            get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }
        ), presenting: deletingProfile) { profile in
            Button("Cancel", role: .cancel) { deletingProfile = nil }
            Button("Delete Profile", role: .destructive) {
                deletingProfile = nil
                selectedProfileID = nil
                Task { await application.deleteProfile(profile.id) }
            }
        } message: { _ in
            Text("This closes its windows and permanently deletes its Spaces, Favorites, tabs, cookies, logins, and website data from Early. Other profiles and Apple Passwords are not affected. This cannot be undone.")
        }
        .alert("Profile update", isPresented: Binding(
            get: { application.profileError != nil }, set: { if !$0 { application.profileError = nil } }
        )) {
            Button("OK") { application.profileError = nil }
        } message: { Text(application.profileError ?? "") }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings").font(.system(size: 21, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("settings.title")
                .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 25)
            ForEach(BrowserSettingsSection.allCases) { section in
                Button { application.settingsSection = section } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 13, weight: application.settingsSection == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                        .background {
                            if application.settingsSection == section {
                                RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(colorScheme == .dark ? 0.10 : 0.065))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus(cornerRadius: 9)
                .overlay {
                    if application.settingsSection == section, contrast == .increased {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(.primary, lineWidth: 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityAddTraits(application.settingsSection == section ? .isSelected : [])
                .accessibilityIdentifier("settings.section.\(section.key)")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary).padding(12)
        }
        .padding(.horizontal, 12).padding(.bottom, 10).frame(width: Self.navigationWidth)
    }

    @ViewBuilder private var sectionContent: some View {
        switch application.settingsSection {
        case .profiles: profilesSection
        case .passwords: PasswordsSettingsSection(application: application, preferences: preferences, lock: application.passwordsLock)
        case .extensions: ExtensionsSettingsSection(application: application)
        case .privacy: PrivacySettingsSection(application: application)
        case .shortcuts: ShortcutsSettingsSection(preferences: preferences)
        case .appearance: appearanceSection
        case .sidebar: sidebarSection
        case .search: searchSection
        case .sessions: sessionsSection
        }
    }

    private var selectedProfile: BrowserProfile? {
        application.profiles.first { $0.id == selectedProfileID }
            ?? application.profiles.first { $0.id == application.workspace?.activeProfileID }
            ?? application.profiles.first
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                Label("Separate cookies, logins, and website data", systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                Text("Each profile has its own Spaces and Favorites. Windows in the same profile share website data. Opening another profile keeps your current pages intact.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("YOUR PROFILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { profileEditor = .new } label: { Label("New Profile", systemImage: "plus") }
                    .disabled(!application.canEditProfiles).accessibilityIdentifier("profile.create")
            }
            VStack(spacing: 8) {
                ForEach(application.profiles) { profile in profileRow(profile) }
            }
            if let profile = selectedProfile {
                spacesCard(profile)
            }
            if let error = application.persistence?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func profileRow(_ profile: BrowserProfile) -> some View {
        HStack(spacing: 12) {
            Button { selectedProfileID = profile.id } label: {
                HStack(spacing: 12) {
                    ProfileAvatar(profile: profile)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(profile.name).font(.body.weight(.medium))
                            if profile.id == application.workspace?.defaultProfileID {
                                Text("Default").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                                    .accessibilityIdentifier("profile.defaultBadge.\(profile.id)")
                            }
                        }
                        let count = application.workspace?.session(for: profile.id)?.spaces.count ?? 0
                        Text("\(count) \(count == 1 ? "Space" : "Spaces")\(profile.id == application.workspace?.activeProfileID ? " · Current profile" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).browserKeyboardFocus().accessibilityLabel(profile.name).accessibilityIdentifier("profile.\(profile.id)")
            Button("Open") { application.openProfile(profile.id) }
                .disabled(application.profileOperationInProgress).accessibilityIdentifier("profile.open.\(profile.id)")
            Menu {
                Button("Edit Profile…") { profileEditor = .edit(profile) }
                Button("Make Default") {
                    if !application.setDefaultProfile(profile.id) {
                        application.profileError = "This profile could not be made the default. Please try again."
                    }
                }
                .disabled(profile.id == application.workspace?.defaultProfileID)
                .help("Use this profile for fresh sessions. Restoring a session keeps its last active profile.")
                Divider()
                Button("Delete Profile…", role: .destructive) { deletingProfile = profile }
                    .disabled(profile.id == application.workspace?.defaultProfileID)
            } label: { Image(systemName: "ellipsis").frame(width: 18) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!application.canEditProfiles)
            .accessibilityLabel("Manage \(profile.name)")
            .accessibilityIdentifier("profile.manage.\(profile.id)")
        }
        .padding(14)
        .background(.primary.opacity(selectedProfile?.id == profile.id ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(selectedProfile?.id == profile.id ? 0.16 : 0.07)) }
    }

    private func spacesCard(_ profile: BrowserProfile) -> some View {
        SettingsCard {
            HStack {
                Text("Spaces in \(profile.name)").font(.headline)
                Spacer()
                Button { application.showSpaceEditor(profileID: profile.id, spaceID: nil) } label: { Image(systemName: "plus") }
                    .help("New Space").disabled(!application.canEditProfiles)
            }
            ForEach(application.workspace?.session(for: profile.id)?.spaces ?? []) { space in
                HStack(spacing: 10) {
                    SpaceIconView(icon: space.icon, size: 12).frame(width: 20)
                    Text(space.name)
                    Spacer()
                    Circle().fill(space.color.tint).frame(width: 9, height: 9).accessibilityLabel(space.color.rawValue)
                    Button("Edit…") { application.showSpaceEditor(profileID: profile.id, spaceID: space.id) }
                        .disabled(!application.canEditProfiles)
                        .accessibilityIdentifier("settings.space.edit.\(space.id)")
                }
                .padding(.vertical, 5)
            }
            Text("Use Edit Space to change its profile. Moving between profiles reloads its pages; logins are not transferred.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                Text("Appearance").font(.headline)
                HStack(spacing: 12) {
                    ForEach(BrowserPreferences.Appearance.allCases, id: \.self) { appearance in
                        appearanceOption(appearance)
                    }
                }
            }
            SettingsCard {
                SettingsToggle("Space themes", detail: "Tint the browser chrome with each Space’s chosen color.", isOn: $preferences.spaceThemes, identifier: "settings.spaceThemes")
                Divider().padding(.vertical, 6)
                SettingsToggle("Translucent chrome", detail: "Let a little of your desktop show through the sidebar and frame. Websites stay unchanged.", isOn: $preferences.translucentChrome, identifier: "settings.translucency")
            }
            Text("Space colors adapt to light and dark appearance. Accessibility settings for contrast and reduced transparency always take priority.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if WebViewManager.supportsPictureInPicture {
                SettingsCard {
                    SettingsToggle("Automatic Picture in Picture", detail: "When you switch away from a tab that’s playing a video, keep watching it in a floating window. It returns to the page when you come back.", isOn: $preferences.automaticPictureInPicture, identifier: "settings.automaticPictureInPicture")
                }
            }
            DefaultBrowserCard(application: application)
            if let updater = application.updater, updater.isAvailable {
                UpdatesCard(updater: updater, preferences: preferences)
            }
        }
    }

    private func appearanceOption(_ appearance: BrowserPreferences.Appearance) -> some View {
        let dark = appearance == .dark || (appearance == .system && colorScheme == .dark)
        let selected = preferences.appearance == appearance
        return Button { preferences.appearance = appearance } label: {
            VStack(spacing: 10) {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(dark ? .white.opacity(0.35) : .black.opacity(0.25)).frame(width: 4, height: 4) } }
                        RoundedRectangle(cornerRadius: 3).fill(dark ? .white.opacity(0.12) : .black.opacity(0.08)).frame(height: 7)
                        Spacer()
                    }
                    .frame(width: 24).padding(.top, 5)
                    RoundedRectangle(cornerRadius: 5).fill(dark ? Color(white: 0.16) : .white)
                }
                .padding(8).frame(height: 75)
                .background(dark ? Color(white: 0.10) : Color(red: 0.91, green: 0.91, blue: 0.90), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .primary.opacity(0.12), lineWidth: selected ? 2 : 1) }
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(appearance.rawValue.capitalized)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(appearance.rawValue.capitalized)
        .browserKeyboardFocus(cornerRadius: 9)
        .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("settings.appearance.\(appearance.rawValue)")
    }

    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                HStack { Text("Sidebar width").font(.headline); Spacer(); Text("\(Int(preferences.sidebarWidth)) pt").monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: $preferences.sidebarWidth, in: SidebarWidth.minimum...SidebarWidth.maximum, step: 1)
                    .accessibilityLabel("Sidebar width").accessibilityIdentifier("settings.sidebarWidth")
                HStack {
                    Text("Compact"); Spacer()
                    Button("Reset") { preferences.sidebarWidth = SidebarWidth.defaultValue }.buttonStyle(.link)
                    Spacer(); Text("Spacious")
                }.font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                SettingsToggle("Auto-hide sidebar", detail: "Keep more room for the page. Move to the left edge to reveal your tabs.", isOn: $preferences.sidebarAutoHides, identifier: "settings.autoHide")
            }
            SettingsCard {
                SettingsToggle("Swipe between Spaces", detail: "Swipe horizontally over the sidebar. A longer swipe past the last Space creates a new one.", isOn: $preferences.spaceSwipes, identifier: "settings.spaceSwipes")
                Divider().padding(.vertical, 6)
                SettingsToggle("Haptic feedback", detail: "Subtle feedback when moving tabs, folders, and Favorites, or changing Spaces. Requires a supported device and enabled system feedback.", isOn: $preferences.haptics, identifier: "settings.haptics")
            }
            SettingsCard {
                SettingsToggle("Return pins and Favorites to their saved page", detail: "Closing a pin or Favorite takes it back to the page you saved. Turn this off to keep the page it was on; Reset to Pinned URL still returns it.", isOn: $preferences.pinsResetWhenClosed, identifier: "settings.pinsResetWhenClosed")
            }
            SettingsCard {
                SettingsToggle("Control-Tab shows the tab switcher", detail: "Hold Control and press Tab to pick from your recent tabs. Turn this off to go straight to the next tab in the sidebar.", isOn: $preferences.controlTabShowsSwitcher, identifier: "settings.controlTabSwitcher")
            }
        }
    }

    private var searchSection: some View {
        let engine = preferences.searchEngine
        return SettingsCard {
            HStack {
                Label("Search engine", systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Picker("Search engine", selection: $preferences.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("settings.searchEngine")
            }
            Text("Searches from the command bar and from selected text use \(engine.name). You can also enter a website address directly.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 6)
            if engine.offersSuggestions {
                SettingsToggle("Online search suggestions", detail: "Send what you type in the command bar to \(engine.name) for suggestions. Turn this off to keep typed queries local until you search.", isOn: $preferences.onlineSuggestions, identifier: "settings.onlineSuggestions")
                Divider().padding(.vertical, 6)
                SettingsToggle("Suggestions in private windows", detail: "Also send what you type in a private window’s command bar to \(engine.name). Off by default, so private typing stays local until you search.", isOn: $preferences.privateOnlineSuggestions, identifier: "settings.privateOnlineSuggestions")
                    .disabled(!preferences.onlineSuggestions)
            } else {
                Label("\(engine.name) doesn’t offer suggestions Early can use without your sign-in, so what you type stays on this Mac until you search. Nothing is sent to another search engine instead.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.noSuggestions")
            }
            Divider().padding(.vertical, 6)
            SettingsToggle("Command bar actions", detail: "Include browser commands, Spaces, and profiles when searching in the command bar. Turn this off to show only matching tabs, pins, Favorites, and web suggestions.", isOn: $preferences.commandBarActions, identifier: "settings.commandBarActions")
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsToggle("Restore previous session", detail: "Reopen your profiles, windows, Spaces, and tabs on launch. When off, keep saved Spaces, folders, pins, and Favorites, but start without open tabs.", isOn: $preferences.restoreSession, identifier: "settings.restoreSession")
                Text("Applies the next time Early launches.").font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                SettingsToggle("Show the command bar in empty windows", detail: "When Early opens, or a new window opens, without a tab, show the command bar ready to type. Early’s first launch always shows it.", isOn: $preferences.showsCommandBarInEmptyWindows, identifier: "settings.commandBarInEmptyWindows")
            }
            SettingsCard {
                HStack {
                    Label("Local session", systemImage: application.persistence?.error == nil ? "checkmark.shield" : "exclamationmark.triangle").font(.headline)
                    Spacer()
                    Text(application.persistence?.isSaving == true ? "Saving…" : application.persistence?.error == nil ? "Saved" : "Needs attention")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("settings.saveStatus")
                }
                Text("Your organization is saved automatically on this Mac. Cookies and logins stay in each profile’s separate WebKit store. This is local storage, not cross-device sync.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = application.persistence?.error { Text(error).font(.callout).foregroundStyle(.red) }
                else if let date = application.persistence?.lastSavedAt { Text("Last saved \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    Button("Save Now") {
                        application.saveAll()
                        Task { sessionMessage = await application.persistence?.flush() == true ? "Session saved." : "Could not save. Your existing snapshot was kept." }
                    }
                    .disabled(application.persistence?.isAvailable != true || application.persistence?.isSaving == true)
                    .accessibilityIdentifier("settings.saveNow")
                    Button("Show in Finder") {
                        if let url = application.storageURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(application.storageURL == nil)
                }
                if let sessionMessage { Text(sessionMessage).font(.caption).foregroundStyle(.secondary) }
            }
            StatePortabilityCard(application: application)
        }
    }
}

/// Hide only the visible Settings title, retaining the title for accessibility
/// and the Window menu, and preserving native traffic lights and their layout.
struct BrowserSettingsWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }

    func updateNSView(_ view: AppearanceView, context: Context) { view.configureWindow() }

    static func configure(_ window: NSWindow) {
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    }

    final class AppearanceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            if let window { BrowserSettingsWindowAppearance.configure(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

/// A change that couldn't be written to disk: why, that it lasts only until
/// Early quits, and Try Again. Compact in a panel, a card in Settings.
struct SaveFailureNotice: View {
    let message: String
    var compact = false
    let identifier: String
    let retry: () -> Void

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                Label("Not saved", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry).controlSize(.small).accessibilityIdentifier(identifier)
            }
            .padding(.vertical, 4)
        } else {
            SettingsCard {
                Label("Your latest changes weren’t saved", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry).accessibilityIdentifier(identifier)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.08))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let identifier: String
    init(_ title: String, detail: String, isOn: Binding<Bool>, identifier: String) {
        self.title = title; self.detail = detail; _isOn = isOn; self.identifier = identifier
    }
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).fixedSize()
                .accessibilityLabel(title).accessibilityHint(detail)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProfileAvatar: View {
    let profile: BrowserProfile
    var body: some View {
        Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(profile.color.tint).frame(width: 38, height: 38)
            .background(profile.color.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(profile.color.tint.opacity(0.2)) }
            .accessibilityHidden(true)
    }
}

private enum ProfileEditorRequest: Identifiable {
    case new, edit(BrowserProfile)
    var id: String { switch self { case .new: "new"; case .edit(let profile): profile.id.uuidString } }
    var profile: BrowserProfile? { if case .edit(let profile) = self { profile } else { nil } }
}

private struct ProfileEditorSheet: View {
    let application: EarlyAppDelegate
    let request: ProfileEditorRequest
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: BrowserSpace.Color
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(application: EarlyAppDelegate, request: ProfileEditorRequest, onSave: @escaping (UUID) -> Void) {
        self.application = application; self.request = request; self.onSave = onSave
        _name = State(initialValue: request.profile?.name ?? "")
        _color = State(initialValue: request.profile?.color ?? .blue)
    }

    private var valid: Bool {
        guard let normalized = BrowserSpace.normalizedName(name) else { return false }
        return !application.profiles.contains { $0.id != request.profile?.id && $0.name.lowercased() == normalized.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ProfileAvatar(profile: BrowserProfile(name: name.isEmpty ? "?" : name, color: color))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.profile == nil ? "New Profile" : "Edit Profile").font(.title3.weight(.semibold))
                    Text("A separate home for your browsing.").font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
                .focused($nameFocused).accessibilityIdentifier("profile.name").onSubmit(save)
            Text("Profile color").font(.callout.weight(.medium))
            HStack(spacing: 9) {
                ForEach(BrowserSpace.Color.allCases, id: \.self) { option in
                    Button { color = option } label: {
                        Circle().fill(option.tint).frame(width: 23, height: 23)
                            .overlay {
                                if color == option { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(option.accessibleCheckmark) }
                            }.frame(width: 28, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(option.rawValue.capitalized)
                    .browserKeyboardFocus()
                    .accessibilityAddTraits(color == option ? .isSelected : [])
                    .accessibilityIdentifier("profile.color.\(option.rawValue)")
                }
            }
            if request.profile == nil {
                Text("Starts with an empty Space and separate cookies, logins, and website data. Nothing is copied from your other profiles.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            else if !name.isEmpty && !valid { Text("Use a unique name with 1–64 characters and no line breaks.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.profile == nil ? "Create Profile" : "Save", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!valid || !application.canEditProfiles)
                    .accessibilityIdentifier("profile.save")
            }
        }
        .padding(26).frame(width: 370)
        .browserReducedMotion()
        .task { await Task.yield(); nameFocused = true }
    }

    private func save() {
        guard valid else { return }
        if let profile = request.profile {
            if application.editProfile(profile.id, name: name, color: color) { onSave(profile.id) }
            else { error = "This profile could not be saved. Please try again." }
        } else if let id = application.createProfile(name: name, color: color) { onSave(id) }
        else { error = "This profile could not be created. Please try again." }
    }
}
