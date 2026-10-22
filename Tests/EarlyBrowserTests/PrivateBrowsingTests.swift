// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Testing
import WebKit

/// Private windows through the real application controller: no windows are
/// presented, storage is a temporary folder, and WebKit stores are ephemeral.
@Suite(.serialized) @MainActor
struct PrivateBrowsingTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPrivate-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.private.\(UUID())"
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

        func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func cleanup() async {
            for id in opened { application.closeWindow(id) }
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private enum Failure: Error { case timeout(String) }

    @Test func privateSessionsHaveOneSpaceNamedPrivateAndSuggestionsStartOff() throws {
        let session = BrowserSession.privateWindow()
        #expect(session.spaces.map(\.name) == ["Private"] && session.spaces.first?.icon == .symbol(.masks))
        #expect(session.activeSpaceID == session.spaces.first?.id && session.tabs.isEmpty)
        try session.validate()
        let defaults = UserDefaults(suiteName: "local.early.tests.private.prefs.\(UUID())")!
        #expect(!BrowserPreferences(defaults: defaults).privateOnlineSuggestions)
    }

    @Test func privateWindowsShareAMemoryOnlyStoreSaveNothingAndReleaseItWhenTheLastCloses() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let normal = try #require(app.model)
        let activeProfile = app.workspace?.activeProfileID

        let first = try #require(app.openPrivateWindow())
        let model = try #require(app.windowModel(first))
        let profile = try #require(app.privateProfileID)
        #expect(model.isPrivate && model.coordinator.profileID == profile && !normal.isPrivate)
        #expect(model.coordinator.spaces.map(\.name) == ["Private"] && model.coordinator.activeSpace?.color == .purple)
        #expect(model.history == nil && !model.canPerform(.showHistory), "Private windows record no history")
        #expect(!model.webViews.websiteDataStore.isPersistent)
        #expect(!app.profiles.contains { $0.id == profile }, "The private profile is never a saved profile")

        let second = try #require(app.openPrivateWindow())
        let sibling = try #require(app.windowModel(second))
        #expect(sibling.coordinator.profileID == profile && sibling.webViews.websiteDataStore === model.webViews.websiteDataStore,
                "Private windows share one session until the last one closes")

        // Browse privately; nothing reaches the session file or the profile's history.
        #expect(model.openLocations([URL(string: "early-test://fixture/two?private=1")!]))
        let tab = try #require(model.coordinator.focusedTabID)
        try await fixture.waitUntil("private page") { model.webViews.pages[tab]?.isLoading == false && model.webViews.pages[tab]?.view.url != nil }
        app.focusedWindow(first)
        #expect(app.workspace?.activeProfileID == activeProfile, "Focusing a private window never changes the active profile")
        app.saveAll()
        #expect(await app.persistence?.flush() == true)
        let saved = try #require(try await SessionRepository(fileURL: fixture.directory.appending(path: "session.sqlite"),
            input: NavigationInput(allowedSchemes: ["http", "https", "file", "early-test"])).loadWorkspace())
        #expect(!saved.sessions.contains { $0.profileID == profile })
        let savedURLs = saved.sessions.flatMap { [$0] + $0.additionalWindows }.flatMap(\.tabs).map(\.currentURL.absoluteString)
        #expect(!savedURLs.contains { $0.contains("private=1") })
        await normal.flushHistory()
        if let history = normal.history { #expect(try await history.visits(matching: "private").isEmpty) }

        // New Window from a private window is an ordinary window.
        let ordinary = try #require(app.openNewWindow(from: model))
        #expect(app.windowModel(ordinary)?.isPrivate == false)
        app.closeWindow(ordinary)

        // Closing the last private window releases the session; the next is fresh.
        app.closeWindow(first)
        #expect(app.privateProfileID == profile, "Still in use by the other private window")
        app.closeWindow(second)
        #expect(app.privateProfileID == nil)
        let third = try #require(app.openPrivateWindow())
        let fresh = try #require(app.windowModel(third))
        #expect(fresh.coordinator.profileID != profile && fresh.webViews.websiteDataStore !== model.webViews.websiteDataStore)
        fixture.opened.removeAll { [first, second, ordinary].contains($0) }
        await fixture.cleanup()
    }

    @Test func privateWindowsOfferNoSavedPagesSpacesOrOnlineSuggestionsByDefault() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        fixture.preferences.onlineSuggestions = true
        let id = try #require(app.openPrivateWindow())
        let model = try #require(app.windowModel(id))
        #expect(!model.onlineSuggestionsEnabled && app.model?.onlineSuggestionsEnabled == true)
        fixture.preferences.privateOnlineSuggestions = true
        #expect(model.onlineSuggestionsEnabled, "Both settings allow it")
        fixture.preferences.onlineSuggestions = false
        #expect(!model.onlineSuggestionsEnabled)

        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let tab = try #require(model.coordinator.focusedTabID)
        #expect(!model.canPerform(.setPinned(tab, true)) && !model.canPerform(.setFavorite(tab, true)))
        #expect(!model.placeTab(tab, in: .pinned) && !model.placeTab(tab, in: .favorites))
        #expect(!model.canPerform(.newSpace) && !model.canManageSpaces)
        #expect(model.canPerform(.closeTab(tab)) && model.canPerform(.newPrivateWindow))
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(!titles.contains("Pin Tab") && !titles.contains("Add to Favorites") && !titles.contains("New Space"))
        #expect(app.model?.commandSearchCandidates().map(\.title).contains("New Private Window") == true)
        await fixture.cleanup()
    }
}
