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

    /// A file can't quietly turn off updates or turn on automatic fill: those
    /// change only when the person agrees, and the sheet lists them first.
    @Test func sensitiveSettingsChangeOnlyWhenTheImportSaysSo() throws {
        let suite = "local.early.tests.archive.\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let here = BrowserPreferences(defaults: store)
        here.checksForUpdatesAutomatically = true
        here.installsUpdatesAutomatically = false
        here.fillsPasswordsAutomatically = false
        here.privateOnlineSuggestions = false
        var file = here.portableSettings
        file.toggles["checksForUpdatesAutomatically"] = false
        file.toggles["fillsPasswordsAutomatically"] = true
        file.toggles["spaceSwipes"] = !here.spaceSwipes
        let changes = here.sensitiveChanges(from: file)
        #expect(changes.map(\.title) == ["Fill passwords automatically", "Check for updates automatically"])
        #expect(changes.map(\.value) == [true, false])

        let swipes = here.spaceSwipes
        here.apply(file)
        #expect(here.checksForUpdatesAutomatically && !here.fillsPasswordsAutomatically, "Not without saying so")
        #expect(here.spaceSwipes != swipes, "Ordinary settings still move")
        here.apply(file, includingSensitive: true)
        #expect(!here.checksForUpdatesAutomatically && here.fillsPasswordsAutomatically)
        #expect(here.sensitiveChanges(from: file).isEmpty)
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
