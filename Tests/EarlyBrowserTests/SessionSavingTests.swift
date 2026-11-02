// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct SessionSavingTests {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var started = false
        func wait() async {
            started = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private actor Writes {
        let second = Gate(), third = Gate()
        let failLast: Bool
        var snapshots: [BrowserWorkspace] = []
        init(failLast: Bool) { self.failLast = failLast }
        func save(_ value: BrowserWorkspace, revision: UInt64) async throws {
            snapshots.append(value)
            if revision == 1 { throw CocoaError(.fileWriteNoPermission) }
            if revision == 2 { await second.wait() }
            if revision == 3 {
                await third.wait()
                if failLast { throw CocoaError(.fileWriteOutOfSpace) }
            }
        }
    }
    private func started(_ gate: Gate) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.started) {
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(arguments: [false, true])
    func errorsStayVisibleUntilTheLatestSnapshotFinishes(failLast: Bool) async throws {
        let writes = Writes(failLast: failLast)
        let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("UnusedSaving-\(UUID()).sqlite"))
        let writer = SessionAutosaver(repository: repository, disabledReason: nil, delay: .zero,
            write: { try await writes.save($0, revision: $1) })
        defer { Task { await writes.second.release(); await writes.third.release(); _ = await writer.flush() } }
        var snapshot = BrowserWorkspace()
        writer.enqueue(snapshot)
        #expect(await writer.flush() == false && writer.error != nil)
        let failure = writer.error
        snapshot.profiles[0].name = "Older retry"
        writer.enqueue(snapshot)
        try await started(writes.second)
        snapshot.profiles[0].name = "Latest edit"
        writer.enqueue(snapshot)
        await writes.second.release()
        try await started(writes.third)
        #expect(writer.isSaving && writer.error == failure, "An older success must not hide the current error")
        await writes.third.release()
        #expect(await writer.flush() == !failLast)
        #expect(!writer.isSaving && (writer.error != nil) == failLast)
        #expect(await writes.snapshots.last?.profiles[0].name == "Latest edit")
    }

    @Test func unavailableStorageCannotBeReportedSaved() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedUnavailable-\(UUID()).sqlite")
        let writer = SessionAutosaver(repository: SessionRepository(fileURL: file), disabledReason: "Storage needs repair.", delay: .zero)
        writer.enqueue(BrowserWorkspace())
        #expect(!writer.isAvailable && !writer.isSaving)
        #expect(await writer.flush() == false && writer.error == "Storage needs repair.")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySaving-\(UUID())")
        let suite = "local.early.tests.saving.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let app = EarlyAppDelegate()
        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
        }
        func start() async {
            _ = await app.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
            _ = await app.persistence?.flush()
        }
        func cleanup() async {
            _ = await app.persistence?.flush()
            app.closeWindow(nil)
            _ = await app.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func retryCapturesCurrentOrganizationWithoutReplacingLivePages() async throws {
        let f = Fixture(); await f.start()
        let app = f.app, model = try #require(f.app.model), file = try #require(f.app.storageURL)
        let url = try #require(URL(string: "early-test://fixture/one"))
        _ = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        model.activateSelection(); app.saveAll()
        #expect(await app.persistence?.flush() == true)
        let page = try #require(model.activePage?.view), selected = model.coordinator.activeTabID
        try await withLockedSession(at: file) {
            app.saveAll()
            #expect(await app.persistence?.flush() == false)
        }
        // Deliberately omit save() to prove Retry reads current model state.
        _ = model.coordinator.createFolder(name: "Latest folder")
        #expect(await app.retrySessionSave())
        #expect(app.persistence?.error == nil && !app.isRetryingSessionSave)
        #expect(model.activePage?.view === page && model.coordinator.activeTabID == selected)
        let stored = try await SessionRepository(fileURL: file,
            input: NavigationInput(allowedSchemes: ["http", "https", "early-test"])).loadWorkspace()
        #expect(stored?.sessions.first?.folders.contains { $0.name == "Latest folder" } == true)
        await f.cleanup()
    }

    @Test func retryWorksWithOnlySettingsOpenAndRetainsFailureForAnotherAttempt() async throws {
        let f = Fixture(); await f.start()
        let app = f.app, file = try #require(f.app.storageURL)
        app.closeWindow(nil)
        #expect(app.model == nil)
        try await withLockedSession(at: file) {
            app.saveAll()
            #expect(await app.persistence?.flush() == false)
            #expect(await app.retrySessionSave() == false)
            #expect(app.persistence?.error != nil && app.canRetrySessionSave)
        }
        #expect(await app.retrySessionSave())
        #expect(app.model == nil && app.persistence?.error == nil)
        #expect(try await SessionRepository(fileURL: file).loadWorkspace() != nil)
        await f.cleanup()
    }
}
