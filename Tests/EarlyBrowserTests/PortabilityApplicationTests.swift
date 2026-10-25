// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
@testable import EarlyCore
import Foundation
import Testing

/// Exporting and importing Early's state, links from other apps, the default
/// browser and the first-run welcome, through the real application
/// controller. No window is presented and the Mac's default browser is never
/// touched.
@Suite(.serialized) @MainActor
struct PortabilityApplicationTests {
    private let one = URL(string: "early-test://fixture/one")!
    private let two = URL(string: "early-test://fixture/two")!
    private let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPortability-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.portability.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        var opened: [UUID] = []

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            application.presentWindow = { [weak self] in self?.opened.append($0) }
        }

        func start() async {
            _ = await application.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
        }

        func cleanup() async {
            _ = await application.persistence?.flush()
            for id in opened { application.closeWindow(id) }
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func openTab(_ url: URL, in model: BrowserWindowModel) throws -> UUID {
        let id = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        model.activateSelection()
        return id
    }

    /// Waits until the test pages ("Page One", "Page Two") have their titles.
    /// A title arriving after a snapshot would change the workspace by itself.
    private func waitUntilLoaded(_ models: [BrowserWindowModel]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while models.flatMap({ $0.coordinator.tabStore.tabs.filter(\.isOpen) }).contains(where: { !$0.title.hasPrefix("Page ") }) {
            try #require(ContinuousClock.now < deadline, "Test pages loaded")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func anExportLeavesOutPrivateWindowsAndImportingAddsAProfileThatLoadsNothing() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let tab = try openTab(one, in: model)
        let privateWindow = try #require(app.openPrivateWindow(from: model).flatMap { app.windowModel($0) })
        #expect(privateWindow.openLocations([two]))
        fixture.preferences.searchEngine = .bing
        let archive = try #require(app.stateArchive())
        let text = try #require(String(data: try archive.encoded(), encoding: .utf8))
        #expect(text.contains("fixture/one") && !text.contains("fixture/two"), "Private windows are never exported")
        #expect(archive.workspace.profiles.count == 1 && archive.settings?.searchEngine == "bing")
        fixture.preferences.searchEngine = .google

        let opened = fixture.opened.count
        let outcome = await app.importState(archive, mode: .addProfiles, includeSettings: false)
        #expect(outcome.succeeded, "\(outcome.message)")
        #expect(app.profiles.map(\.name) == ["Default", "Default 2"])
        #expect(fixture.preferences.searchEngine == .google, "Settings stay unless chosen")
        let backup = try #require(outcome.backup)
        #expect(backup.deletingLastPathComponent() == app.backupsDirectory && backup.lastPathComponent.hasPrefix("Before Import "))
        #expect(try EarlyStateArchive.decode(Data(contentsOf: backup), using: input).workspace.profiles.count == 1,
                "The backup is what was here before")

        #expect(fixture.opened.count == opened + 1, "The profile had a window open, so it opens again")
        let window = try #require(fixture.opened.last.flatMap { app.windowModel($0) })
        #expect(window.coordinator.profileID == app.profiles[1].id)
        #expect(window.coordinator.tabStore.tabs.contains { $0.isOpen && $0.currentURL == one })
        #expect(window.coordinator.activeTabID == nil && window.webViews.creationCount == 0, "Nothing loads until it's chosen")
        #expect(window.webViews.websiteDataStore !== model.webViews.websiteDataStore, "A new profile signs in afresh")
        #expect(model.webViews.existingView(for: tab) != nil && model.coordinator.activeTabID == tab, "Your own pages are untouched")

        #expect(await app.persistence?.flush() == true)
        let saved = try await SessionRepository(fileURL: fixture.directory.appendingPathComponent("session.sqlite"), input: input).loadWorkspace()
        #expect(saved?.profiles.map(\.name) == ["Default", "Default 2"])

        // With its settings this time.
        _ = await app.importState(archive, mode: .addProfiles, includeSettings: true)
        #expect(fixture.preferences.searchEngine == .bing && app.profiles.count == 3)
        await fixture.cleanup()
    }

    @Test func replacingAnOpenProfileShowsTheFileInItsWindowsAndKeepsItsWebsiteData() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let profile = model.coordinator.profileID
        let store = model.webViews.websiteDataStore
        _ = try openTab(one, in: model)
        let archive = try #require(app.stateArchive())
        // Changed after exporting: another page and a second window.
        let later = try openTab(two, in: model)
        #expect(model.perform(.newWindow))
        let extra = try #require(fixture.opened.last)

        let outcome = await app.importState(archive, mode: .replaceMatching, includeSettings: false)
        #expect(outcome.succeeded, "\(outcome.message)")
        #expect(app.profiles.map(\.id) == [profile] && app.model === model)
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == [one])
        #expect(model.webViews.existingView(for: later) == nil && model.coordinator.activeTabID == nil)
        #expect(model.webViews.websiteDataStore === store, "Still signed in to its websites")
        #expect(app.windowModel(extra) == nil, "The file had one window")
        #expect(app.workspace?.session(for: profile)?.additionalWindows.isEmpty == true)
        await fixture.cleanup()
    }

    @Test func aFailedImportChangesNothingAndAClosedProfileReopensAllItsWindows() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        _ = try openTab(one, in: model)
        model.onOpenWindow?(two, "Sibling")
        let sibling = try #require(fixture.opened.last.flatMap { app.windowModel($0) })
        try await waitUntilLoaded([model, sibling])
        var archive = try #require(app.stateArchive())
        #expect(archive.workspace.sessions.first?.additionalWindows.count == 1)

        var broken = archive
        broken.workspace.profiles = []
        let before = app.workspace
        let failed = await app.importState(broken, mode: .addProfiles, includeSettings: true)
        #expect(!failed.succeeded && failed.backup == nil && app.workspace == before)
        #expect(app.backupsDirectory.map { FileManager.default.fileExists(atPath: $0.path) } == false, "No backup for nothing")

        // A profile that was closed when exported is added closed, with its windows.
        archive.workspace.openProfileIDs = []
        let opened = fixture.opened.count
        #expect(await app.importState(archive, mode: .addProfiles, includeSettings: false).succeeded)
        #expect(fixture.opened.count == opened)
        let imported = try #require(app.profiles.last?.id)
        #expect(app.workspace?.session(for: imported)?.additionalWindows.count == 1)
        app.openProfile(imported)
        let windows = fixture.opened.dropFirst(opened).compactMap { app.windowModel($0) }
        #expect(windows.count == 2 && windows.allSatisfy { $0.coordinator.profileID == imported })
        #expect(Set(windows.flatMap { $0.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) }) == [one, two])
        await fixture.cleanup()
    }

    @Test func aStorageFailureLeavesImportUnappliedAndRetrySucceeds() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        _ = try openTab(one, in: model)
        fixture.preferences.searchEngine = .bing
        let archive = try #require(app.stateArchive())
        fixture.preferences.searchEngine = .google
        let later = try openTab(two, in: model)
        let view = try #require(model.webViews.existingView(for: later))
        try await waitUntilLoaded([model])
        app.saveAll()
        #expect(await app.persistence?.flush() == true)
        let before = app.workspace
        let file = fixture.directory.appendingPathComponent("session.sqlite")
        let repository = SessionRepository(fileURL: file, input: input)
        let durable = try await repository.loadWorkspace()

        try await withLockedSession(at: file) {
            let operation = Task { await app.importState(archive, mode: .replaceMatching, includeSettings: true) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !app.profileOperationInProgress {
                try #require(ContinuousClock.now < deadline, "Import started")
                await Task.yield()
            }
            #expect(!model.canPerform(.closeTab(later)), "Editing waits for the import transaction")
            let failed = await operation.value
            #expect(!failed.succeeded)
            #expect(app.workspace == before)
            #expect(model.webViews.existingView(for: later) === view, "Failed import must preserve the live document")
            #expect(model.coordinator.activeTabID == later && fixture.preferences.searchEngine == .google)
            let saved = try await repository.loadWorkspace()
            #expect(saved == durable)
        }
        let retried = await app.importState(archive, mode: .replaceMatching, includeSettings: true)
        #expect(retried.succeeded && fixture.preferences.searchEngine == .bing)
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == [one])
        #expect(try await repository.loadWorkspace() == app.workspace)
        await fixture.cleanup()
    }

    @Test func anUnwritableBackupLeavesTheWorkspaceAndSettingsUntouched() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        _ = try openTab(one, in: model)
        try await waitUntilLoaded([model])
        let archive = try #require(app.stateArchive())
        let before = app.workspace
        let directory = try #require(app.backupsDirectory)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: directory.path, isDirectory: false))
        let failed = await app.importState(archive, mode: .replaceMatching, includeSettings: true)
        #expect(!failed.succeeded && failed.backup == nil && app.workspace == before)
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == [one])
        await fixture.cleanup()
    }

    @Test func theWindowInFrontIsFoundByItsIdentifier() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let primary = try #require(app.model)
        func window(_ identifier: String?) -> NSWindow {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
            return window
        }
        #expect(app.browserModel(for: window("browser")) === primary)
        let id = try #require(app.openNewWindow())
        #expect(app.browserModel(for: window("browser.\(id)")) === app.windowModel(id))
        #expect(app.browserModel(for: window("com_apple_SwiftUI_Settings_window")) == nil, "Settings isn't a browser window")
        #expect(app.browserModel(for: window(nil)) == nil && app.browserModel(for: nil) == nil)
        // macOS 26 renamed a second window after it registered: it's still that window.
        let renamed = window("browser.\(id)")
        app.windowDidRegister(id, window: renamed)
        renamed.identifier = NSUserInterfaceItemIdentifier("browser-AppWindow-2")
        let second = try #require(app.windowModel(id))
        #expect(app.browserModel(for: renamed) === second && app.nativeWindow(of: second) === renamed)
        #expect(app.browserModel(for: window("browser-AppWindow-2")) == nil, "Only the window that registered")
        // ⌘W's title: whether the window in front shows a page, kept as its
        // page comes and goes.
        func eventually(_ condition: () -> Bool) async -> Bool {
            var attempts = 0
            while !condition(), attempts < 200 { attempts += 1; try? await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        let front = window("browser")
        app.updateFrontWindow(front)
        #expect(primary.showsNoPage && !app.frontWindowState.showsPage)
        app.openExternalLinks([one])
        #expect(await eventually { app.frontWindowState.showsPage }, "A page opened in the window in front")
        primary.perform(.closeActiveTab)
        #expect(await eventually { !app.frontWindowState.showsPage }, "Its page closed")
        app.openExternalLinks([one])
        app.updateFrontWindow(window("com_apple_SwiftUI_Settings_window"))
        #expect(!app.frontWindowState.showsPage, "Settings in front, before the browser window's page")
        primary.perform(.closeActiveTab)
        app.openExternalLinks([one])
        #expect(await eventually { primary.coordinator.activeTabID != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!app.frontWindowState.showsPage, "Only the window in front is followed")
        app.closeWindow(nil)
        #expect(app.browserModel(for: window("browser")) == nil, "A closed window is never the one in front")
        await fixture.cleanup()
    }

    @Test func linksFromOtherAppsOpenInTheFrontOrdinaryWindowOrANewOne() async throws {
        let fixture = Fixture()
        let app = fixture.application
        // Launched by a link: it waits for the first window.
        app.openExternalLinks([one, URL(string: "javascript:alert(1)")!, URL(string: "ftp://files.example/")!])
        await fixture.start()
        let model = try #require(app.model)
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == [one])
        #expect(model.coordinator.activeTabID != nil && model.coordinator.commandBar == nil)
        #expect(fixture.opened.isEmpty)

        app.openExternalLinks([two])
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).count == 2 && fixture.opened.isEmpty)
        app.openExternalLinks(Array(repeating: one, count: 25))
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).count == 2 + EarlyAppDelegate.externalLinkLimit)

        // With only a private window open, a link gets an ordinary window.
        let privateWindow = try #require(app.openPrivateWindow(from: model).flatMap { app.windowModel($0) })
        app.closeWindow(nil)
        app.openExternalLinks([two])
        #expect(privateWindow.coordinator.tabStore.tabs.isEmpty, "Never in a private window")
        let created = try #require(fixture.opened.last.flatMap { app.windowModel($0) })
        #expect(!created.isPrivate && created.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == [two])
        await fixture.cleanup()
    }

    /// Help's links open as tabs in Early, in the window in front.
    @Test func helpLinksOpenAsTabsInEarly() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        #expect(BrowserCommands.helpLinks.map(\.title) == ["Early Website", "Release Notes", "Report an Issue"])
        #expect(BrowserCommands.helpLinks.allSatisfy { $0.url.scheme == "https" && (try? model.input.validate($0.url)) != nil })
        app.openExternalLinks(BrowserCommands.helpLinks.map(\.url))
        #expect(model.coordinator.tabStore.tabs.filter(\.isOpen).map(\.currentURL) == BrowserCommands.helpLinks.map(\.url))
        #expect(BrowserCommands.helpLinks.first?.url.absoluteString == "https://earlybrowser.github.io/web/")
        await fixture.cleanup()
    }

    @MainActor private final class FakeSystem {
        var isDefault = false
        var answer = true
        var asked = 0
    }

    @Test func defaultStatusIsWhatMacOSSaysAndDecliningIsRespected() async throws {
        let fixture = Fixture()
        let app = fixture.application
        let system = FakeSystem()
        app.defaultBrowser = DefaultBrowser(isDefault: { system.isDefault }, makeDefault: {
            system.asked += 1
            if system.answer { system.isDefault = true }
        })
        await fixture.start()
        #expect(!app.isDefaultBrowser)
        system.answer = false
        await app.makeDefaultBrowser()
        #expect(system.asked == 1 && !app.isDefaultBrowser, "Keeping another browser is respected")
        system.answer = true
        await app.makeDefaultBrowser()
        #expect(app.isDefaultBrowser)
        // Chosen elsewhere, in System Settings: seen when Early comes back.
        system.isDefault = false
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(!app.isDefaultBrowser)
        await fixture.cleanup()

        // Tests never use the Mac's own setting.
        let other = Fixture()
        await other.start()
        await other.application.makeDefaultBrowser()
        #expect(!other.application.isDefaultBrowser)
        await other.cleanup()
    }

    @Test func theWelcomeShowsOnceOnTheFirstWindowBelowAFocusedCommandBar() throws {
        let suite = "local.early.tests.welcome.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
        func model(_ startup: StartupContext, isPrivate: Bool = false) -> BrowserWindowModel {
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyWelcome-\(UUID()).sqlite"), input: input)
            return BrowserWindowModel(startup: startup, session: isPrivate ? .privateWindow() : BrowserSession(), repository: repository,
                                      input: input, isTesting: true, restorationError: nil, defaults: defaults,
                                      preferences: preferences, isPrivate: isPrivate)
        }
        let returning = model(.returningSession)
        let incognito = model(.firstLaunch, isPrivate: true)
        #expect(!returning.showsWelcome && !incognito.showsWelcome)
        let first = model(.firstLaunch)
        #expect(first.showsWelcome && first.coordinator.commandBar?.intent == .newTab && first.coordinator.activeTabID == nil,
                "The first usable state is still the command bar over empty content")
        first.finishWelcome()
        #expect(!first.showsWelcome && defaults.bool(forKey: BrowserWindowModel.welcomeCompletedKey))
        let again = model(.firstLaunch)
        #expect(!again.showsWelcome, "Once on this Mac")

        let tips = WelcomeCard.tips(preferences.shortcuts)
        #expect(tips.count == 6 && tips[0].detail.contains("⌘T") && tips[0].detail.contains("⌘L"))
        preferences.shortcuts.assign(BrowserShortcut("k"), to: .newTab)
        #expect(WelcomeCard.tips(preferences.shortcuts)[0].detail.contains("⌘K"), "It names your own shortcut")
        for window in [returning, incognito, first, again] { window.cancelCommandBarQueries(); window.webViews.discardAll() }
    }

    @Test func importPreviewDescribesEachProfile() throws {
        let summary = EarlyStateArchive.ProfileSummary(id: UUID(), name: "Work", spaces: 2, favorites: 1, pins: 0, folders: 3,
                                                       windows: 2, openTabs: 1, match: BrowserProfile(name: "work"))
        #expect(StateImportSheet.contents(summary) == "2 Spaces, 1 Favorite, 3 folders, 1 open tab, 2 windows")
        #expect(StateImportSheet.result(summary, mode: .replaceMatching) == "Replaces work")
        #expect(StateImportSheet.result(summary, mode: .addProfiles) == "New profile")
        #expect(StatePortabilityCard.fileName(on: Date(timeIntervalSince1970: 1_792_800_000)).hasSuffix(".json"))
    }
}
