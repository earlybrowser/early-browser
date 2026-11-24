// SPDX-License-Identifier: MPL-2.0

@testable import EarlyCore
import Foundation
import Testing

/// Exporting and importing Early's state: what a file holds, how it is
/// checked, and how importing adds or replaces profiles without collisions.
@Suite @MainActor
struct StateArchiveTests {
    private let input = NavigationInput()
    private let docs = URL(string: "https://docs.example/start")!
    private let mail = URL(string: "https://mail.example/")!
    private let news = URL(string: "https://news.example/today")!
    private let board = URL(string: "https://board.example/")!

    /// Two Spaces, nested folders, a pin in a folder, a Favorite, Today tabs
    /// in a split, a second window and a recently closed tab; plus a second,
    /// empty profile.
    private func workspace() throws -> BrowserWorkspace {
        let profile = UUID(), personal = UUID(), work = UUID()
        let spaces = [BrowserSpace(id: personal, profileID: profile, name: "Personal"),
                      BrowserSpace(id: work, profileID: profile, name: "Work", color: .green, icon: .symbol(.masks))]
        let folder = BrowserFolder(spaceID: personal, name: "Reading")
        var child = BrowserFolder(spaceID: personal, parentID: folder.id, name: "Later", isExpanded: true)
        child.sidebarPosition = 1
        var pin = BrowserTab(spaceID: personal, profileID: profile, title: "Docs", currentURL: docs, pinnedURL: docs, isOpen: false)
        pin.folderID = child.id
        let favorite = BrowserTab(spaceID: personal, profileID: profile, title: "Mail", currentURL: mail, pinnedURL: mail,
                                  isOpen: false, isFavorite: true)
        var today = BrowserTab(spaceID: personal, profileID: profile, title: "News", currentURL: news, customTitle: "Morning")
        today.recordActivation(at: Date())
        let beside = BrowserTab(spaceID: personal, profileID: profile, title: "Board", currentURL: board)
        let elsewhere = BrowserTab(spaceID: work, profileID: profile, title: "Board", currentURL: board)
        let closed = BrowserTab(spaceID: personal, profileID: profile, title: "Old", currentURL: URL(string: "https://old.example/")!)
        let split = BrowserSplitGroup(spaceID: personal, panes: [BrowserSplitPane(tabID: today.id), BrowserSplitPane(tabID: beside.id)],
                                      leadingFraction: 0.4)
        var root = BrowserSession(profileID: profile, activeSpaceID: personal, tabs: [pin, favorite, today, beside],
                                  selectionBySpace: [personal: today.id], recentlyClosed: [ClosedTab(tab: closed, position: 0)],
                                  folders: [folder, child], spaces: spaces, splitGroups: [split],
                                  focusedPaneByGroupID: [split.id: split.panes[0].id])
        root.additionalWindows = [BrowserSession(profileID: profile, activeSpaceID: work, tabs: [pin, favorite, elsewhere],
                                                 selectionBySpace: [work: elsewhere.id], folders: [folder, child], spaces: spaces)]
        var workspace = BrowserWorkspace(session: root)
        let created = workspace.createProfile(name: "School", color: .orange)
        let school = try #require(created)
        workspace.openProfileIDs = [profile, school]
        try workspace.validate(using: input)
        return workspace
    }

    private func ids(_ workspace: BrowserWorkspace) -> Set<UUID> {
        var ids = Set(workspace.profiles.map(\.id))
        for window in workspace.sessions.flatMap({ [$0] + $0.additionalWindows }) {
            ids.formUnion(window.spaces.map(\.id) + window.tabs.map(\.id) + window.folders.map(\.id) + window.splitGroups.map(\.id)
                          + window.splitGroups.flatMap { $0.panes.map(\.id) })
        }
        return ids
    }

    private func workspace(withProfiles count: Int) throws -> BrowserWorkspace {
        var workspace = BrowserWorkspace()
        for index in 1..<count { try #require(workspace.createProfile(name: "Profile \(index)") != nil) }
        return workspace
    }

    private func unvalidatedBytes(of workspace: BrowserWorkspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(EarlyStateArchive(workspace: workspace, settings: nil))
    }

    @Test(arguments: [32, 33, EarlyStateArchive.maximumProfiles])
    func profileBoundsRoundTripThroughTheFileWriter(count: Int) throws {
        var workspace = try workspace(withProfiles: count)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyProfiles-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try EarlyStateArchive.write(workspace: workspace, settings: nil, to: file)
        #expect(try EarlyStateArchive.read(from: file, using: input).workspace == workspace)
        if count == EarlyStateArchive.maximumProfiles {
            #expect(workspace.createProfile(name: "One extra") == nil)
            #expect(workspace.profiles.count == count)
        }
    }

    @Test func aValidArchiveCannotMakeTheDestinationExceedTheProfileLimit() throws {
        let source = try workspace(withProfiles: EarlyStateArchive.maximumProfiles)
        let archive = try EarlyStateArchive.decode(EarlyStateArchive(workspace: source, settings: nil).encoded())
        let current = BrowserWorkspace()
        #expect(throws: EarlyStateArchive.Problem.tooManyProfiles) { try archive.merged(into: current, mode: .addProfiles) }
        let replacement = try archive.merged(into: current, mode: .replaceMatching)
        let bytes = try EarlyStateArchive(workspace: replacement.workspace, settings: nil).encoded()
        #expect(try EarlyStateArchive.decode(bytes).workspace.profiles.count == EarlyStateArchive.maximumProfiles)
        #expect(replacement.replaced == [current.defaultProfileID])
    }

    @Test func anOversizedLegacySessionCanBeRecoveredAndLeavesOlderBackupsIntact() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("EarlyLegacySession-\(UUID())")
        let live = directory.appendingPathComponent("Live"), recovered = directory.appendingPathComponent("Recovered")
        let backups = directory.appendingPathComponent("Backups")
        defer { try? files.removeItem(at: directory) }
        let supported = try workspace(withProfiles: EarlyStateArchive.maximumProfiles)
        var legacy = supported
        let extra = BrowserSession()
        legacy.profiles.append(BrowserProfile(id: extra.profileID, name: "Legacy profile"))
        legacy.sessions.append(extra)
        do {
            let repository = SessionRepository(fileURL: live.appendingPathComponent("session.sqlite"))
            try await repository.saveWorkspace(legacy, revision: 1)
        }
        try files.copyItem(at: live, to: recovered)
        let repository = SessionRepository(fileURL: recovered.appendingPathComponent("session.sqlite"))
        #expect(try await repository.loadWorkspace() == legacy)
        #expect(throws: EarlyStateArchive.Problem.tooManyProfiles) { try EarlyStateArchive.decode(unvalidatedBytes(of: legacy)) }

        var saved: [URL] = []
        for _ in 0..<6 {
            saved.append(try EarlyStateArchive.backup(workspace: supported, settings: nil, in: backups, retaining: 6))
        }
        #expect(throws: EarlyStateArchive.Problem.tooManyProfiles) {
            try EarlyStateArchive.backup(workspace: legacy, settings: nil, in: backups, retaining: 5)
        }
        #expect(Set(try files.contentsOfDirectory(atPath: backups.path)) == Set(saved.map(\.lastPathComponent)))
        #expect(try EarlyStateArchive.read(from: #require(saved.last), using: input).workspace == supported)
    }

    @Test func backupReportsALockedObsoleteFileAndRetentionRecoversOnRetry() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("EarlyLockedBackup-\(UUID())")
        let workspace = BrowserWorkspace()
        let old = try EarlyStateArchive.backup(workspace: workspace, settings: nil, in: directory, retaining: 1)
        defer {
            try? files.setAttributes([.immutable: false], ofItemAtPath: old.path)
            try? files.removeItem(at: directory)
        }
        try files.setAttributes([.immutable: true], ofItemAtPath: old.path)
        let saved = try EarlyStateArchive.writeBackup(workspace: workspace, settings: nil, in: directory, retaining: 1)
        #expect(saved.retentionWarning != nil && saved.url != old)
        let both = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(both.count == 2)
        for file in both { #expect(try EarlyStateArchive.read(from: file, using: input).workspace == workspace) }

        try files.setAttributes([.immutable: false], ofItemAtPath: old.path)
        let newest = try EarlyStateArchive.writeBackup(workspace: workspace, settings: nil, in: directory, retaining: 1)
        #expect(newest.retentionWarning == nil)
        #expect(try files.contentsOfDirectory(atPath: directory.path) == [newest.url.lastPathComponent])
    }

    @Test func tabCapacityCountsEveryWindowAndRejectsGrowthAcrossTheLimit() throws {
        var session = BrowserSession()
        let limit = EarlyStateArchive.maximumTabs
        func newTab() -> BrowserTab {
            BrowserTab(spaceID: session.activeSpaceID, profileID: session.profileID, title: "Page", currentURL: docs)
        }
        session.tabs = (0..<(limit / 2)).map { _ in newTab() }
        let siblingTabs = (session.tabs.count..<limit).map { _ in newTab() }
        session.additionalWindows = [BrowserSession(profileID: session.profileID, activeSpaceID: session.activeSpaceID,
                                               tabs: siblingTabs, spaces: session.spaces)]
        var full = BrowserWorkspace(session: session)
        let archive = EarlyStateArchive(workspace: full, settings: nil)
        let loaded = try EarlyStateArchive.decode(archive.encoded())
        #expect(loaded.workspace == full)

        var single = BrowserSession()
        single.tabs = [BrowserTab(spaceID: single.activeSpaceID, profileID: single.profileID, title: "Extra", currentURL: mail)]
        let addition = EarlyStateArchive(workspace: BrowserWorkspace(session: single), settings: nil)
        #expect(throws: EarlyStateArchive.Problem.tooManyTabs) { try addition.merged(into: full, mode: .addProfiles) }

        full.sessions[0].additionalWindows[0].tabs.append(newTab())
        #expect(throws: EarlyStateArchive.Problem.tooManyTabs) { try EarlyStateArchive(workspace: full, settings: nil).encoded() }
        #expect(throws: EarlyStateArchive.Problem.tooManyTabs) { try EarlyStateArchive.decode(unvalidatedBytes(of: full)) }
    }

    @Test func archivesAtTheByteLimitReopenAndLargerWritesLeaveTheDestinationIntact() throws {
        var root = BrowserSession()
        root.tabs = [BrowserTab(spaceID: root.activeSpaceID, profileID: root.profileID, title: "Page", currentURL: docs)]
        var workspace = BrowserWorkspace(session: root)
        let base = try EarlyStateArchive(workspace: workspace, settings: nil).encoded().count
        workspace.sessions[0].tabs[0].title += String(repeating: "x", count: EarlyStateArchive.maximumSize - base)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyFullArchive-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try EarlyStateArchive.write(workspace: workspace, settings: nil, to: file)
        let previous = try Data(contentsOf: file)
        #expect(previous.count == EarlyStateArchive.maximumSize)
        let archive = try EarlyStateArchive.read(from: file, using: input)
        #expect(archive.workspace == workspace)
        #expect(throws: EarlyStateArchive.Problem.tooLarge) { try archive.merged(into: BrowserWorkspace(), mode: .addProfiles) }

        workspace.sessions[0].tabs[0].title += "x"
        #expect(throws: EarlyStateArchive.Problem.tooLarge) { try EarlyStateArchive.write(workspace: workspace, settings: nil, to: file) }
        #expect(try Data(contentsOf: file) == previous)
        #expect(throws: EarlyStateArchive.Problem.tooLarge) { try EarlyStateArchive.decode(previous + Data([0x20])) }
    }

    @Test func anExportRoundTripsWithoutRecentlyClosedTabsOrUsage() throws {
        let original = try workspace()
        let preferences = BrowserPreferences(defaults: UserDefaults(suiteName: "local.early.tests.archive.\(UUID())")!)
        preferences.searchEngine = .duckDuckGo
        let archive = EarlyStateArchive(workspace: original, settings: preferences.portableSettings)
        let data = try archive.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"format\" : \"early-state\"") && text.contains("https://docs.example/start"))
        #expect(!text.contains("old.example"), "Recently closed tabs stay on this Mac")
        #expect(!text.contains("lastActivatedAt"))

        let decoded = try EarlyStateArchive.decode(data, using: input)
        #expect(decoded == archive)
        let root = try #require(decoded.workspace.sessions.first)
        #expect(root.recentlyClosed.isEmpty && root.tabs.allSatisfy { $0.activationCount == 0 })
        #expect(root.additionalWindows.count == 1 && root.splitGroups.count == 1 && root.folders.count == 2)
        #expect(root.tabs.first { $0.customTitle == "Morning" } != nil)
        #expect(decoded.workspace.session(for: decoded.workspace.profiles[1].id)?.tabs.isEmpty == true, "An empty profile stays empty")
        #expect(decoded.settings?.searchEngine == "duckDuckGo")
    }

    @Test func onlyAValidFileOfThisVersionIsRead() throws {
        let data = try EarlyStateArchive(workspace: try workspace(), settings: nil).encoded()
        func problem(_ data: Data) -> EarlyStateArchive.Problem? {
            do { _ = try EarlyStateArchive.decode(data, using: input); return nil }
            catch { return error as? EarlyStateArchive.Problem }
        }
        func edited(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            change(&json)
            return try JSONSerialization.data(withJSONObject: json)
        }
        #expect(problem(data) == nil)
        #expect(problem(Data(count: EarlyStateArchive.maximumSize + 1)) == .tooLarge)
        #expect(problem(Data("{\"profiles\": []}".utf8)) == .notAnArchive)
        #expect(problem(Data("not json".utf8)) == .notAnArchive)
        #expect(problem(data.prefix(data.count / 2)) == .notAnArchive, "Cut short")
        #expect(problem(try edited { $0["version"] = 2 }) == .newerVersion)
        #expect(problem(try edited { $0["format"] = "chrome-bookmarks" }) == .notAnArchive)
        #expect(problem(try edited { $0["workspace"] = ["profiles": []] }) == .invalid)
        // An address Early won't open makes the whole file unusable.
        let script = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "https://docs.example/start", with: "javascript:alert(1)")
        #expect(problem(Data(script.utf8)) == .invalid)
        // So do two profiles sharing a name.
        #expect(problem(Data(String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"School\"", with: "\"Default\"").utf8)) == .invalid)
    }

    @Test func olderSessionsInsideAFileAreMigrated() throws {
        let profile = UUID(), tab = UUID(), space = UUID()
        let old = """
        {"format": "early-state", "version": 1, "exportedAt": "2026-10-01T09:00:00Z", "workspace": {
          "workspaceVersion": 1, "defaultProfileID": "\(profile)", "activeProfileID": "\(profile)", "openProfileIDs": ["\(profile)"],
          "profiles": [{"id": "\(profile)", "name": "Default", "color": "gray"}],
          "sessions": [{"version": 1, "profileID": "\(profile)", "activeSpaceID": "\(space)", "selectionBySpace": [], "recentlyClosed": [],
            "tabs": [{"id": "\(tab)", "spaceID": "\(space)", "profileID": "\(profile)", "title": "Docs",
                      "currentURL": "https://docs.example/start", "pinnedURL": "https://docs.example/start", "isOpen": false}]}]}}
        """
        let archive = try EarlyStateArchive.decode(Data(old.utf8), using: input)
        let session = try #require(archive.workspace.sessions.first)
        #expect(session.version == 2 && session.spaces.map(\.id) == [space] && session.tabs.first?.pinnedURL == docs)
    }

    @Test func addingGivesEveryRecordANewIdentityAndKeepsItsRelationships() throws {
        let exported = try workspace()
        let archive = EarlyStateArchive(workspace: exported, settings: nil)
        let current = BrowserWorkspace()
        let result = try archive.merged(into: current, mode: .addProfiles, using: input)
        let merged = result.workspace
        #expect(merged.profiles.map(\.name) == ["Default", "Default 2", "School"])
        #expect(merged.defaultProfileID == current.defaultProfileID && merged.activeProfileID == current.activeProfileID)
        #expect(merged.session(for: current.defaultProfileID) == current.session(for: current.defaultProfileID), "Yours is untouched")
        #expect(result.replaced.isEmpty && result.profiles.count == 2 && result.openProfiles == result.profiles)
        #expect(ids(merged).isDisjoint(with: ids(exported)), "Nothing keeps an identity from the file")

        let root = try #require(merged.session(for: result.profiles[0]))
        #expect(root.selectionBySpace.isEmpty, "Nothing loads until it's chosen")
        #expect(root.additionalWindows.first?.selectionBySpace.isEmpty == true)
        #expect(root.recentlyClosed.isEmpty)
        let pin = try #require(root.tabs.first { $0.pinnedURL == docs })
        let later = try #require(root.folders.first { $0.name == "Later" })
        let reading = try #require(root.folders.first { $0.name == "Reading" })
        #expect(pin.folderID == later.id && later.parentID == reading.id && later.sidebarPosition == 1 && !later.isExpanded)
        #expect(root.additionalWindows.first?.tabs.contains { $0.id == pin.id } == true, "A pin stays shared by its windows")
        #expect(root.additionalWindows.first?.spaces == root.spaces)
        let group = try #require(root.splitGroups.first)
        #expect(group.leadingFraction == 0.4 && Set(group.panes.map(\.tabID)).isSubset(of: Set(root.tabs.map(\.id))))
        #expect(root.focusedPaneByGroupID[group.id] == group.panes[0].id)
        #expect(root.spaces.last.map { $0.name == "Work" && $0.color == .green && $0.icon == .symbol(.masks) } == true)
        #expect(root.tabs.allSatisfy { $0.profileID == result.profiles[0] } && root.spaces.allSatisfy { $0.profileID == result.profiles[0] })

        // The same file again: still no clashes, and the names stay unique.
        let again = try archive.merged(into: merged, mode: .addProfiles, using: input)
        #expect(again.workspace.profiles.map(\.name) == ["Default", "Default 2", "School", "Default 3", "School 2"])
        try again.workspace.validate(using: input)
    }

    @Test func replacingChangesOnlyTheMatchingProfilesAndKeepsTheirIdentity() throws {
        let exported = try workspace()
        let archive = EarlyStateArchive(workspace: exported, settings: nil)
        // This Mac: the exported default itself, and a different "school" with a page.
        var current = exported
        current.sessions = current.sessions.filter { $0.profileID == exported.defaultProfileID }
        current.profiles = current.profiles.filter { $0.id == exported.defaultProfileID }
        current.openProfileIDs = [exported.defaultProfileID]
        let createdSchool = current.createProfile(name: "school")
        let school = try #require(createdSchool)
        let createdPersonal = current.createProfile(name: "Personal")
        let personal = try #require(createdPersonal)
        let summary = archive.summary(against: current)
        #expect(summary.map(\.match?.id) == [exported.defaultProfileID, school])
        #expect(summary[0].openTabs == 3 && summary[0].pins == 1 && summary[0].favorites == 1 && summary[0].windows == 2)

        let result = try archive.merged(into: current, mode: .replaceMatching, using: input)
        let merged = result.workspace
        #expect(result.profiles == [exported.defaultProfileID, school] && result.replaced == [exported.defaultProfileID, school])
        #expect(merged.profiles.map(\.name) == ["Default", "School", "Personal"], "The file's name is used")
        #expect(merged.session(for: personal) == current.session(for: personal), "Profiles not in the file are untouched")
        #expect(merged.session(for: exported.defaultProfileID)?.tabs.count == 4)
        #expect(merged.session(for: school)?.tabs.isEmpty == true && merged.session(for: school)?.spaces.first?.profileID == school)
        #expect(ids(merged).intersection(ids(exported)) == [exported.defaultProfileID], "Only the profile keeps its identity")

        // Adding instead leaves both of this Mac's profiles as they were.
        let added = try archive.merged(into: current, mode: .addProfiles, using: input)
        #expect(added.replaced.isEmpty && added.workspace.profiles.count == 5)
        #expect(added.workspace.session(for: exported.defaultProfileID) == current.session(for: exported.defaultProfileID))
    }

    /// A file can't quietly change updates or private-window suggestions: those
    /// change only when the person agrees, and the sheet lists them first.
    @Test func sensitiveSettingsChangeOnlyWhenTheImportSaysSo() throws {
        let suite = "local.early.tests.archive.\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let here = BrowserPreferences(defaults: store)
        here.checksForUpdatesAutomatically = true
        here.installsUpdatesAutomatically = false
        here.privateOnlineSuggestions = false
        var file = here.portableSettings
        file.toggles["checksForUpdatesAutomatically"] = false
        file.toggles["fillsPasswordsAutomatically"] = true
        file.toggles["privateOnlineSuggestions"] = true
        file.toggles["spaceSwipes"] = !here.spaceSwipes
        let changes = here.sensitiveChanges(from: file)
        #expect(changes.map(\.title) == ["Search suggestions in private windows", "Check for updates automatically"])
        #expect(changes.map(\.value) == [true, false])

        let swipes = here.spaceSwipes
        here.apply(file)
        #expect(here.checksForUpdatesAutomatically && !here.privateOnlineSuggestions, "Not without saying so")
        #expect(here.spaceSwipes != swipes, "Ordinary settings still move")
        here.apply(file, includingSensitive: true)
        #expect(!here.checksForUpdatesAutomatically && here.privateOnlineSuggestions)
        #expect(here.sensitiveChanges(from: file).isEmpty)
        #expect(here.portableSettings.toggles["fillsPasswordsAutomatically"] == nil, "Legacy exports cannot restore automatic filling")
        #expect(store.object(forKey: "fillsPasswordsAutomatically") == nil)
    }

    @Test func settingsMoveOnlyThroughTheAllowList() throws {
        let suite = "local.early.tests.archive.\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let source = BrowserPreferences(defaults: store)
        source.searchEngine = .kagi
        source.appearance = .dark
        source.spaceSwipes = false
        source.sidebarWidth = 300
        source.shortcuts.assign(BrowserShortcut("k", [.command, .shift]), to: .duplicateTab)
        let settings = source.portableSettings
        #expect(settings.toggles.count == BrowserPreferences.portableToggles.count && settings.toggles["spaceSwipes"] == false)

        let targetSuite = "local.early.tests.archive.\(UUID())"
        let targetStore = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetStore.removePersistentDomain(forName: targetSuite) }
        let target = BrowserPreferences(defaults: targetStore)
        target.apply(try JSONDecoder().decode(PortableSettings.self, from: JSONEncoder().encode(settings)))
        #expect(target.searchEngine == .kagi && target.appearance == .dark && !target.spaceSwipes && target.sidebarWidth == 300)
        #expect(target.shortcuts.shortcut(for: .duplicateTab)?.display == "⇧⌘K")

        // Unknown names, unreadable values and unusable shortcuts are skipped.
        let odd = Data("""
        {"toggles": {"haptics": false, "sendEverythingEverywhere": true}, "appearance": "sepia", "searchEngine": 7,
         "sidebarWidth": "wide", "shortcuts": {"newTab": {"key": "q", "modifiers": 1}}}
        """.utf8)
        let fresh = BrowserPreferences(defaults: targetStore)
        fresh.apply(try JSONDecoder().decode(PortableSettings.self, from: odd))
        #expect(!fresh.haptics && fresh.appearance == .dark && fresh.searchEngine == .kagi && fresh.sidebarWidth == 300)
        #expect(fresh.shortcuts.shortcut(for: .newTab)?.display == "⌘T", "⌘Q is macOS's")
        var clash = BrowserShortcuts()
        clash.assign(BrowserShortcut("t"), to: .duplicateTab, replacing: true)
        #expect(clash.isUsable)
        let twice = try JSONDecoder().decode(BrowserShortcuts.self, from: Data(#"{"duplicateTab":{"key":"t","modifiers":1}}"#.utf8))
        #expect(!twice.isUsable, "Two commands can't share ⌘T")
    }
}
