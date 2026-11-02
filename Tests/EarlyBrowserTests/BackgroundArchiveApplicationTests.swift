// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct BackgroundArchiveApplicationTests {
    private actor BackupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false
        private(set) var calls = 0
        func pauseFirst() async {
            calls += 1
            guard calls == 1 else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyArchiveWorker-\(UUID())")
        let suite = "local.early.tests.archiveworker.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let app = EarlyAppDelegate()
        var opened: [UUID] = []
        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            app.presentWindow = { [weak self] in self?.opened.append($0) }
        }
        func start() async {
            _ = await app.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                                    defaults: defaults, storageDirectory: directory, isTesting: true)
        }
        func cleanup() async {
            _ = await app.persistence?.flush()
            opened.forEach { app.closeWindow($0) }
            app.closeWindow(nil)
            _ = await app.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func wait(_ gate: BackupGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.started) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func open(_ name: String, in model: BrowserWindowModel) async throws -> UUID {
        let url = try #require(URL(string: "early-test://fixture/\(name)"))
        let id = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        model.activateSelection()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.coordinator.tabStore.tab(id: id)?.title.hasPrefix("Page ") != true {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        return id
    }

    @Test func preparingAndBackingUpRebaseOnInterveningTabsAndSettings() async throws {
        let fixture = Fixture(), gate = BackupGate()
        await fixture.start()
        let app = fixture.app, model = try #require(app.model)
        _ = try await open("one", in: model)
        let archive = try #require(app.stateArchive())
        let writer = app.archiveBackupWriter
        app.archiveBackupWriter = { workspace, settings, directory in
            await gate.pauseFirst()
            return try await writer(workspace, settings, directory)
        }
        let operation = Task { await app.importState(archive, mode: .addProfiles, includeSettings: false) }
        try await wait(gate)
        #expect(!app.profileOperationInProgress && app.canEditProfiles, "Preparation must not freeze other browsing")
        let second = try await open("two", in: model)
        let view = try #require(model.webViews.existingView(for: second))
        fixture.preferences.searchEngine = .bing
        await gate.release()
        let outcome = await operation.value
        #expect(outcome.succeeded)
        #expect(await gate.calls >= 2, "A stale backup/result must be rebuilt against the latest state")
        #expect(model.coordinator.activeTabID == second && model.webViews.existingView(for: second) === view)
        #expect(fixture.preferences.searchEngine == .bing && app.profiles.count == 2)
        let backup = try await app.readStateArchive(at: #require(outcome.backup))
        #expect(backup.settings?.searchEngine == "bing")
        #expect(backup.workspace.sessions.flatMap(\.tabs).contains { $0.id == second })
        await fixture.cleanup()
    }

    @Test func cancellingDuringBackupLeavesLivePagesAndProfilesUntouched() async throws {
        let fixture = Fixture(), gate = BackupGate()
        await fixture.start()
        let app = fixture.app, model = try #require(app.model)
        let tab = try await open("one", in: model)
        let view = try #require(model.webViews.existingView(for: tab)), archive = try #require(app.stateArchive())
        let writer = app.archiveBackupWriter
        app.archiveBackupWriter = { workspace, settings, directory in
            await gate.pauseFirst()
            return try await writer(workspace, settings, directory)
        }
        let operation = Task { await app.importState(archive, mode: .replaceMatching, includeSettings: true) }
        try await wait(gate)
        operation.cancel()
        await gate.release()
        let result = await operation.value
        #expect(!result.succeeded && result.message.contains("cancelled"))
        #expect(app.profiles.count == 1 && !app.profileOperationInProgress)
        #expect(model.coordinator.activeTabID == tab && model.webViews.existingView(for: tab) === view)
        await fixture.cleanup()
    }
}
