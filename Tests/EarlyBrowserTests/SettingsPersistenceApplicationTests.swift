// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
@testable import EarlyCore
import Testing

@Suite(.serialized) @MainActor
struct SettingsPersistenceApplicationTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var entered = false
        var started: Bool { lock.withLock { entered } }
        func write(_ bytes: Data, to file: URL) throws {
            #expect(!Thread.isMainThread)
            let first = lock.withLock { let first = !entered; entered = true; return first }
            if first, semaphore.wait(timeout: .now() + 10) != .success { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
        }
        func release() { semaphore.signal() }
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySettingsLifecycle-\(UUID())")
        let suite = "local.early.tests.settingsLifecycle.\(UUID())"
        let defaults: UserDefaults
        let app = EarlyAppDelegate()
        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            app.presentWindow = { _ in }
        }
        func start() async throws -> BrowserWindowModel {
            let preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            _ = await app.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
            return try #require(app.model)
        }
        func cleanup(_ model: BrowserWindowModel) async {
            model.webViews.discardAll()
            await model.flushHistory()
            await model.webViews.favicons.shutdown()
            await model.history?.close()
            for profile in app.profiles {
                _ = await app.sitePermissions(for: profile.id).flush()
                _ = await app.extensionCatalog(for: profile.id).flush()
            }
            _ = await app.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test(arguments: [false, true])
    func terminationWaitsForBothCatalogsEvenAfterTheWindowCloses(closeWindow: Bool) async throws {
        let fixture = Fixture(), model = try await fixture.start(), app = fixture.app
        let permissions = model.sitePermissions, catalog = app.extensionCatalog(for: model.coordinator.profileID)
        #expect(await permissions.load())
        #expect(await catalog.load())
        let permissionGate = Gate(), extensionGate = Gate()
        defer { permissionGate.release(); extensionGate.release() }
        permissions.persistence.writeFile = permissionGate.write
        catalog.persistence.writeFile = extensionGate.write
        permissions.set(.block, for: [.downloads], origin: "https://example.com")
        let item = InstalledExtension(source: .files(folderName: "fixture"), name: "Fixture", version: "1", isEnabled: false)
        catalog.add(item)
        try await wait { permissionGate.started && extensionGate.started }
        if closeWindow { app.closeWindow(nil) }
        var reply: Bool?
        app.terminationReply = { reply = $0 }
        app.askToQuitWithUnsavedSettings = { _ in Issue.record("The pending writes succeed"); return .alertSecondButtonReturn }
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await wait { !permissions.acceptsChanges }
        #expect(reply == nil)
        permissions.set(.allow, for: [.downloads], origin: "https://example.com")
        #expect(permissions.decision(for: "https://example.com", .downloads) == .block, "Late callbacks cannot change the snapshot being saved for quit")
        permissionGate.release()
        try await wait { !permissions.isSaving }
        #expect(reply == nil, "Extension settings must reach disk too")
        extensionGate.release()
        try await wait { reply != nil }
        #expect(reply == true)
        let savedPermissions = SitePermissions(fileURL: permissions.fileURL), savedExtensions = ExtensionCatalog(fileURL: catalog.fileURL)
        #expect(await savedPermissions.load())
        #expect(await savedExtensions.load())
        #expect(savedPermissions.decision(for: "https://example.com", .downloads) == .block && savedExtensions.extensions == [item])
        await fixture.cleanup(model)
    }

    @Test(arguments: [false, true])
    func stalledSettingsOfferCancelOrExplicitQuitAnyway(quitAnyway: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySettingsQuit-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = Gate(), permissions = SitePermissions(fileURL: file)
        defer { gate.release() }
        #expect(await permissions.load())
        permissions.persistence.writeFile = gate.write
        permissions.set(.allow, for: [.camera], origin: "https://example.com")
        try await wait { gate.started }
        var questions = 0
        let result = await EarlyAppDelegate.settingsSaved([permissions], timeout: .milliseconds(30)) { _ in
            questions += 1
            return quitAnyway ? .alertThirdButtonReturn : .alertSecondButtonReturn
        }
        #expect(result == quitAnyway && questions == 1 && permissions.acceptsChanges == !quitAnyway)
        if !quitAnyway { permissions.set(.block, for: [.camera], origin: "https://example.com") }
        gate.release()
        #expect(await permissions.flush())
        let saved = SitePermissions(fileURL: file)
        #expect(await saved.load())
        #expect(saved.decision(for: "https://example.com", .camera) == (quitAnyway ? .allow : .block))
    }

    @Test func quitRetryWritesTheCurrentSettingsAfterFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySettingsRetry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(fileURL: file)
        #expect(await permissions.load())
        permissions.persistence.writeFile = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        permissions.set(.block, for: [.downloads], origin: "https://example.com")
        #expect(!(await permissions.flush()))
        var questions = 0
        let quit = await EarlyAppDelegate.settingsSaved([permissions]) { reason in
            questions += 1
            #expect(reason.contains("couldn’t be saved"))
            permissions.persistence.writeFile = { bytes, url in try bytes.write(to: url, options: .atomic) }
            return .alertFirstButtonReturn
        }
        #expect(quit && questions == 1 && permissions.saveError == nil)
        let saved = SitePermissions(fileURL: file)
        #expect(await saved.load())
        #expect(saved.decision(for: "https://example.com", .downloads) == .block)
    }

    @Test func profileDeletionWaitsForBothWritersAndNeverRecreatesTheirFiles() async throws {
        let fixture = Fixture(), model = try await fixture.start(), app = fixture.app
        let profile = try #require(app.createProfile(name: "Remove", color: .blue))
        let permissions = app.sitePermissions(for: profile), catalog = app.extensionCatalog(for: profile)
        #expect(await permissions.load())
        #expect(await catalog.load())
        let permissionGate = Gate(), extensionGate = Gate()
        defer { permissionGate.release(); extensionGate.release() }
        permissions.persistence.writeFile = permissionGate.write
        catalog.persistence.writeFile = extensionGate.write
        permissions.set(.allow, for: [.camera], origin: "https://example.com")
        let item = InstalledExtension(source: .files(folderName: "fixture"), name: "Fixture", version: "1", isEnabled: false)
        catalog.add(item)
        try await wait { permissionGate.started && extensionGate.started }
        var deleted = false
        let deletion = Task { await app.deleteProfile(profile); deleted = true }
        try await wait { !permissions.acceptsChanges }
        #expect(!deleted)
        permissionGate.release()
        try await wait { catalog.isRemoved }
        catalog.add(item)
        catalog.retrySaving()
        #expect(!deleted && catalog.extensions.isEmpty)
        extensionGate.release()
        await deletion.value
        permissions.set(.allow, for: [.microphone], origin: "https://example.com")
        permissions.retrySaving()
        #expect(!app.profiles.contains { $0.id == profile })
        #expect(!FileManager.default.fileExists(atPath: try #require(permissions.fileURL).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(catalog.fileURL).path))
        #expect(app.profileError == nil)
        #expect(!(fixture.defaults.stringArray(forKey: "pendingProfileCleanup") ?? []).contains(profile.uuidString))
        await fixture.cleanup(model)
    }
}
