// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Settings that can move with an exported copy of Early. Only these are read
/// from a file; anything else in it is ignored.
public struct PortableSettings: Codable, Equatable, Sendable {
    public var toggles: [String: Bool]
    public var appearance: String?
    public var searchEngine: String?
    public var sidebarWidth: Double?
    public var shortcuts: BrowserShortcuts?

    public init(toggles: [String: Bool] = [:], appearance: String? = nil, searchEngine: String? = nil,
                sidebarWidth: Double? = nil, shortcuts: BrowserShortcuts? = nil) {
        self.toggles = toggles
        self.appearance = appearance
        self.searchEngine = searchEngine
        self.sidebarWidth = sidebarWidth
        self.shortcuts = shortcuts
    }

    private enum CodingKeys: String, CodingKey { case toggles, appearance, searchEngine, sidebarWidth, shortcuts }

    // A value that can't be read is skipped rather than refusing the whole file.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toggles = (try? values.decodeIfPresent([String: Bool].self, forKey: .toggles)) ?? [:]
        appearance = (try? values.decodeIfPresent(String.self, forKey: .appearance)) ?? nil
        searchEngine = (try? values.decodeIfPresent(String.self, forKey: .searchEngine)) ?? nil
        sidebarWidth = (try? values.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? nil
        shortcuts = (try? values.decodeIfPresent(BrowserShortcuts.self, forKey: .shortcuts)) ?? nil
    }
}

public extension BrowserPreferences {
    /// The switches an export carries, by name.
    static let portableToggles: [(name: String, path: ReferenceWritableKeyPath<BrowserPreferences, Bool>)] = [
        ("onlineSuggestions", \.onlineSuggestions), ("privateOnlineSuggestions", \.privateOnlineSuggestions),
        ("commandBarActions", \.commandBarActions), ("sidebarAutoHides", \.sidebarAutoHides),
        ("spaceSwipes", \.spaceSwipes), ("haptics", \.haptics), ("spaceThemes", \.spaceThemes),
        ("translucentChrome", \.translucentChrome), ("restoreSession", \.restoreSession),
        ("showsCommandBarInEmptyWindows", \.showsCommandBarInEmptyWindows), ("pinsResetWhenClosed", \.pinsResetWhenClosed),
        ("controlTabShowsSwitcher", \.controlTabShowsSwitcher), ("automaticPictureInPicture", \.automaticPictureInPicture),
        ("checksForUpdatesAutomatically", \.checksForUpdatesAutomatically),
        ("installsUpdatesAutomatically", \.installsUpdatesAutomatically),
    ]

    var portableSettings: PortableSettings {
        PortableSettings(toggles: Dictionary(uniqueKeysWithValues: Self.portableToggles.map { ($0.name, self[keyPath: $0.path]) }),
                         appearance: appearance.rawValue, searchEngine: searchEngine.rawValue, sidebarWidth: sidebarWidth,
                         shortcuts: shortcuts)
    }

    /// Settings that affect privacy or updates: an import changes
    /// them only when the person agrees to each, never along with the rest.
    static let sensitiveToggles: [(name: String, title: String)] = [
        ("privateOnlineSuggestions", "Search suggestions in private windows"),
        ("checksForUpdatesAutomatically", "Check for updates automatically"),
        ("installsUpdatesAutomatically", "Install updates automatically")
    ]

    /// The sensitive settings a file would change here, with the value each would get.
    func sensitiveChanges(from settings: PortableSettings) -> [(title: String, value: Bool)] {
        Self.sensitiveToggles.compactMap { toggle in
            guard let path = Self.portableToggles.first(where: { $0.name == toggle.name })?.path,
                  let value = settings.toggles[toggle.name], value != self[keyPath: path] else { return nil }
            return (toggle.title, value)
        }
    }

    /// Uses what the file has that Early knows, leaving everything else as it
    /// is: the sensitive settings too only when `includingSensitive`.
    func apply(_ settings: PortableSettings, includingSensitive: Bool = false) {
        let sensitive = Set(Self.sensitiveToggles.map(\.name))
        for (name, path) in Self.portableToggles where includingSensitive || !sensitive.contains(name) {
            if let value = settings.toggles[name], self[keyPath: path] != value { self[keyPath: path] = value }
        }
        if let value = settings.appearance.flatMap(Appearance.init(rawValue:)), value != appearance { appearance = value }
        if let value = settings.searchEngine.flatMap(SearchEngine.init(rawValue:)), value != searchEngine { searchEngine = value }
        if let value = settings.sidebarWidth, value.isFinite { sidebarWidth = value }
        if let value = settings.shortcuts, value.isUsable, value != shortcuts { shortcuts = value }
    }
}

/// A copy of Early's state to keep or move to another Mac: settings, and each
/// profile's Spaces, folders, pins, Favorites, windows and open tabs. Never
/// cookies, logins, passwords, history, website data or private windows,
/// which are kept elsewhere and never written here.
public struct EarlyStateArchive: Codable, Equatable, Sendable {
    public static let formatName = "early-state"
    public static let currentVersion = 1
    public static let maximumSize = 16 * 1024 * 1024
    public static let maximumProfiles = 32
    public static let maximumTabs = 20_000

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var settings: PortableSettings?
    public var workspace: BrowserWorkspace

    public enum Problem: Error, Equatable, Sendable {
        case tooLarge, notAnArchive, newerVersion, invalid

        public var message: String {
            switch self {
            case .tooLarge: "The file is too large to be an Early export."
            case .notAnArchive: "The file isn’t an Early export."
            case .newerVersion: "The file was exported by a newer version of Early. Update Early to import it."
            case .invalid: "The file is damaged or incomplete, so nothing was imported."
            }
        }
    }

    /// Recently closed tabs and how often tabs were used stay on this Mac.
    public init(workspace: BrowserWorkspace, settings: PortableSettings?, exportedAt: Date = Date()) {
        format = Self.formatName
        version = Self.currentVersion
        // Whole seconds, as the file stores them.
        self.exportedAt = Date(timeIntervalSince1970: exportedAt.timeIntervalSince1970.rounded(.down))
        self.settings = settings
        var copy = workspace
        copy.browserImportBatchIDs = nil
        for index in copy.sessions.indices {
            copy.sessions[index].removeLocalUsage()
            for window in copy.sessions[index].additionalWindows.indices { copy.sessions[index].additionalWindows[window].removeLocalUsage() }
        }
        self.workspace = copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads a file, checking its size, format, version, structure and
    /// addresses before anything uses it.
    public static func decode(_ data: Data, using input: NavigationInput = NavigationInput()) throws -> Self {
        guard data.count <= maximumSize else { throw Problem.tooLarge }
        struct Header: Decodable { let format: String?; let version: Int? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatName,
              let version = header.version, version >= 1 else { throw Problem.notAnArchive }
        guard version <= currentVersion else { throw Problem.newerVersion }
        guard let archive = try? decoder.decode(Self.self, from: data) else { throw Problem.invalid }
        let windows = archive.workspace.sessions.flatMap { [$0] + $0.additionalWindows }
        guard archive.workspace.profiles.count <= maximumProfiles,
              windows.reduce(0, { $0 + $1.tabs.count }) <= maximumTabs,
              (try? archive.workspace.validate(using: input)) != nil else { throw Problem.invalid }
        return archive
    }

    // MARK: Preview

    public struct ProfileSummary: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let spaces: Int
        public let favorites: Int
        public let pins: Int
        public let folders: Int
        public let windows: Int
        public let openTabs: Int
        /// The profile on this Mac that Replace would change.
        public let match: BrowserProfile?
    }

    public func summary(against current: BrowserWorkspace) -> [ProfileSummary] {
        let matches = self.matches(in: current)
        return workspace.profiles.compactMap { profile in
            guard let session = workspace.session(for: profile.id) else { return nil }
            let windows = [session] + session.additionalWindows
            let today = Set(windows.flatMap { $0.tabs.filter { $0.isOpen && $0.pinnedURL == nil }.map(\.id) })
            return ProfileSummary(id: profile.id, name: profile.name, spaces: session.spaces.count,
                                  favorites: session.tabs.filter(\.isFavorite).count,
                                  pins: session.tabs.filter { $0.pinnedURL != nil && !$0.isFavorite }.count,
                                  folders: session.folders.count, windows: windows.count, openTabs: today.count,
                                  match: matches[profile.id].flatMap { id in current.profiles.first { $0.id == id } })
        }
    }

    /// Each imported profile's counterpart on this Mac: the same profile, or
    /// one with the same name. Each is matched at most once.
    public func matches(in current: BrowserWorkspace) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        var taken = Set<UUID>()
        for profile in workspace.profiles where current.profiles.contains(where: { $0.id == profile.id }) {
            result[profile.id] = profile.id
            taken.insert(profile.id)
        }
        for profile in workspace.profiles where result[profile.id] == nil {
            if let local = current.profiles.first(where: { !taken.contains($0.id) && $0.name.lowercased() == profile.name.lowercased() }) {
                result[profile.id] = local.id
                taken.insert(local.id)
            }
        }
        return result
    }

    // MARK: Import

    public enum ImportMode: String, CaseIterable, Sendable {
        /// Every imported profile becomes a new one beside yours.
        case addProfiles
        /// An imported profile replaces the matching one's Spaces, tabs and
        /// windows (keeping its website data and passwords); others are added.
        case replaceMatching
    }

    public struct ImportResult: Equatable, Sendable {
        public var workspace: BrowserWorkspace
        /// This Mac's profile for each imported one, in the file's order.
        public var profiles: [UUID]
        public var replaced: Set<UUID>
        /// Profiles that had windows open when exported.
        public var openProfiles: [UUID]
    }

    /// The workspace after importing, checked in full. Every Space, folder,
    /// tab and split gets a new identity, so nothing can collide with what is
    /// already here; no tab is selected, so nothing loads until it's chosen.
    public func merged(into current: BrowserWorkspace, mode: ImportMode,
                       using input: NavigationInput = NavigationInput()) throws -> ImportResult {
        guard (try? workspace.validate(using: input)) != nil else { throw Problem.invalid }
        var draft = current
        let matches = mode == .replaceMatching ? self.matches(in: current) : [:]
        var map = IdentityMap()
        var result = ImportResult(workspace: current, profiles: [], replaced: [], openProfiles: [])
        for profile in workspace.profiles {
            guard let session = workspace.session(for: profile.id) else { throw Problem.invalid }
            let target: UUID
            if let local = matches[profile.id], let index = draft.profiles.firstIndex(where: { $0.id == local }) {
                target = local
                let others = draft.profiles.filter { $0.id != local }
                if !others.contains(where: { $0.name.lowercased() == profile.name.lowercased() }) { draft.profiles[index].name = profile.name }
                draft.profiles[index].color = profile.color
                draft.sessions.removeAll { $0.profileID == local }
                result.replaced.insert(local)
            } else {
                target = UUID()
                draft.profiles.append(BrowserProfile(id: target, name: Self.uniqueName(profile.name, in: draft.profiles), color: profile.color))
            }
            draft.sessions.append(session.importing(as: target, map: &map))
            result.profiles.append(target)
            if workspace.openProfileIDs.contains(profile.id) { result.openProfiles.append(target) }
        }
        guard (try? draft.validate(using: input)) != nil else { throw Problem.invalid }
        result.workspace = draft
        return result
    }

    /// "Work", or "Work 2" when there's already a Work.
    static func uniqueName(_ name: String, in profiles: [BrowserProfile]) -> String {
        let base = BrowserSpace.normalizedName(name) ?? "Imported"
        let taken = Set(profiles.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        for number in 2... {
            let suffix = " \(number)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return base
    }
}

/// New identities for imported records, the same one each time an old one is seen.
struct IdentityMap {
    private var values: [UUID: UUID] = [:]

    mutating func callAsFunction(_ id: UUID) -> UUID {
        if let value = values[id] { return value }
        let value = UUID()
        values[id] = value
        return value
    }
}

extension BrowserSession {
    mutating func removeLocalUsage() {
        recentlyClosed = []
        for index in tabs.indices {
            tabs[index].lastActivatedAt = nil
            tabs[index].activationCount = 0
        }
    }

    /// This session's windows for another profile, with new identities and
    /// nothing selected. Saved items shared by its windows stay shared.
    func importing(as profileID: UUID, map: inout IdentityMap) -> BrowserSession {
        var copy = window(as: profileID, map: &map)
        copy.additionalWindows = additionalWindows.map { $0.window(as: profileID, map: &map) }
        return copy
    }

    private func window(as profileID: UUID, map: inout IdentityMap) -> BrowserSession {
        let spaces = self.spaces.map { BrowserSpace(id: map($0.id), profileID: profileID, name: $0.name, color: $0.color, icon: $0.icon) }
        let folders = self.folders.map { folder in
            var copy = BrowserFolder(id: map(folder.id), spaceID: map(folder.spaceID), parentID: folder.parentID.map { map($0) },
                                     name: folder.name, live: folder.live, icon: folder.icon)
            copy.sidebarPosition = folder.sidebarPosition
            return copy
        }
        let tabs = self.tabs.map { tab in
            var copy = BrowserTab(id: map(tab.id), spaceID: map(tab.spaceID), profileID: profileID, title: tab.title,
                                  currentURL: tab.currentURL, pinnedURL: tab.pinnedURL, isOpen: tab.isOpen,
                                  pinnedTitle: tab.pinnedTitle, isFavorite: tab.isFavorite, customTitle: tab.customTitle)
            copy.folderID = tab.folderID.map { map($0) }
            copy.sidebarPosition = tab.sidebarPosition
            copy.liveItemID = tab.liveItemID
            return copy
        }
        let groups = splitGroups.map { group in
            BrowserSplitGroup(id: map(group.id), spaceID: map(group.spaceID),
                              panes: group.panes.map { BrowserSplitPane(id: map($0.id), tabID: map($0.tabID)) },
                              leadingFraction: group.leadingFraction)
        }
        var focus: [UUID: UUID] = [:]
        for (group, pane) in focusedPaneByGroupID { focus[map(group)] = map(pane) }
        return BrowserSession(profileID: profileID, activeSpaceID: map(activeSpaceID), tabs: tabs, folders: folders,
                              spaces: spaces, splitGroups: groups, focusedPaneByGroupID: focus)
    }
}

public extension BrowserShortcuts {
    /// Each could have been chosen in Settings, and no two commands share
    /// one. Shortcuts from a file are used only when they are.
    var isUsable: Bool {
        let assigned = BrowserCommand.allCases.compactMap { shortcut(for: $0) }
        guard Set(assigned).count == assigned.count else { return false }
        return BrowserCommand.allCases.filter(isChanged).compactMap { shortcut(for: $0) }.allSatisfy { shortcut in
            (shortcut.isFunctionKey || !shortcut.modifiers.isDisjoint(with: [.command, .control])) && !Self.reserved.contains(shortcut)
        }
    }
}
