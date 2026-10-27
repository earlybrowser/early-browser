// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import Testing
import EarlyCore
@testable import EarlyBrowser

@Suite(.serialized) @MainActor
struct BrowserImportApplicationTests {
    @MainActor final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyBrowserImportApp-" + UUID().uuidString)
        let suite = "local.early.tests.browserimport." + UUID().uuidString
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            application.presentWindow = { _ in }
        }
        func start(_ app: EarlyAppDelegate? = nil) async {
            _ = await (app ?? application).bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                                                   defaults: defaults, storageDirectory: directory, isTesting: true)
        }
        func cleanup() async {
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func source(withHistory: Bool = false) -> BrowserImportDocument {
        var nodes: [BrowserImportNode] = [.init(id: "profile", kind: .profile, title: "Synthetic Browser"),
            .init(id: "folder", parentID: "profile", kind: .folder, title: "Imported Research"),
            .init(id: "pin", parentID: "folder", kind: .pin, title: "Imported Pin", url: URL(string: "https://example.invalid/pin")!),
            .init(id: "today", parentID: "profile", kind: .openTab, title: "Imported Today", url: URL(string: "https://example.invalid/today")!)]
        if withHistory {
            nodes.append(.init(id: "history", parentID: "profile", kind: .history, title: "Known Visit",
                               url: URL(string: "https://example.invalid/known-visit")!, visitedAt: Date().addingTimeInterval(-30)))
        }
        return .init(source: "Synthetic Browser", nodes: nodes)
    }
    func destinations(_ app: EarlyAppDelegate) -> [String: BrowserImportDestination] {
        let session = app.workspace!.sessions[0]
        return ["profile": .init(profileID: session.profileID, profileName: "Default", spaceID: session.activeSpaceID, spaceName: "Personal")]
    }
    @Test func importingPreservesLiveWebViewsSelectionsMediaAndSiblingWindows() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, model = try #require(fixture.application.model)
        let id = try #require(model.coordinator.navigate(to: URL(string: "early-test://fixture/one")!, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        model.activateSelection()
        let view = try #require(model.webViews.existingView(for: id))
        let count = model.webViews.creationCount
        let siblingID = try #require(app.openNewWindow(from: model))
        let sibling = try #require(app.windowModel(siblingID))
        let siblingTab = try #require(sibling.coordinator.navigate(to: URL(string: "early-test://fixture/two")!, target: .newTab(spaceID: sibling.coordinator.activeSpaceID)))
        sibling.activateSelection()
        let siblingView = try #require(sibling.webViews.existingView(for: siblingTab))
        let siblingCount = sibling.webViews.creationCount
        model.save(); #expect(await app.persistence?.flush() == true)
        let doc = source(withHistory: true)
        let result = await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)), destinations: destinations(app), flatten: false)
        #expect(result.succeeded)
        #expect(model.coordinator.activeTabID == id)
        #expect(model.webViews.existingView(for: id) === view)
        #expect(model.webViews.creationCount == count)
        #expect(model.coordinator.tabStore.tabs.contains { $0.title == "Imported Pin" && !$0.isOpen })
        #expect(model.coordinator.tabStore.tabs.contains { $0.title == "Imported Today" && $0.isOpen })
        #expect(sibling.coordinator.activeTabID == siblingTab)
        #expect(sibling.webViews.existingView(for: siblingTab) === siblingView)
        #expect(sibling.webViews.creationCount == siblingCount)
        #expect(!sibling.coordinator.tabStore.tabs.contains { $0.title == "Imported Today" })
        #expect(sibling.coordinator.tabStore.tabs.contains { $0.title == "Imported Pin" && !$0.isOpen })
        #expect(app.browserImportBatches.count == 1)
        #expect(result.backup != nil)
        let batch = try #require(app.browserImportBatches.first)
        let history = try #require(app.history(for: model.coordinator.profileID))
        #expect(try await history.search("known-visit", limit: 5).count == 1)
        let undo = await app.undoBrowserImport(batch)
        #expect(undo.succeeded && model.coordinator.activeTabID == id)
        #expect(model.webViews.existingView(for: id) === view)
        #expect(try await history.search("known-visit", limit: 5).isEmpty)
        #expect(sibling.webViews.existingView(for: siblingTab) === siblingView)
        app.closeWindow(siblingID)
        await fixture.cleanup()
    }
    @Test func undoSurvivesRestartAndKeepsLaterSavedItems() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source()
        #expect(await app.importBrowser(doc, selected: doc.initiallySelected, destinations: destinations(app), flatten: false).succeeded)
        #expect(await app.persistence?.flush() == true)
        let restarted = EarlyAppDelegate(); restarted.presentWindow = { _ in }
        await fixture.start(restarted)
        let model = try #require(restarted.model), batch = try #require(restarted.browserImportBatches.first)
        let newID = try #require(model.coordinator.navigate(to: URL(string: "https://example.invalid/later")!, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        #expect(model.coordinator.setPinned(newID, pinned: true))
        model.save(); #expect(await restarted.persistence?.flush() == true)
        #expect(await restarted.undoBrowserImport(batch).succeeded)
        #expect(model.coordinator.tabStore.tab(id: newID) != nil)
        #expect(model.webViews.creationCount == 0)
        restarted.closeWindow(nil); _ = await restarted.persistence?.flush()
        await fixture.cleanup()
    }
    @Test func failedSessionCommitRollsBackImportedHistoryAndLeavesLiveStateUntouched() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, model = try #require(fixture.application.model), doc = source(withHistory: true)
        model.save(); #expect(await app.persistence?.flush() == true)
        let before = model.coordinator.session
        let outcome = try await withLockedSession(at: fixture.directory.appendingPathComponent("session.sqlite")) {
            await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)), destinations: destinations(app), flatten: false)
        }
        #expect(!outcome.succeeded)
        #expect(model.coordinator.session == before)
        #expect(app.browserImportBatches.isEmpty)
        let store = try #require(app.history(for: before.profileID))
        #expect(try await store.search("known-visit", limit: 5).isEmpty)
        #expect(await app.persistence?.flush() == true)
        await fixture.cleanup()
    }
    @Test func committedUndoCanRetryHistoryCleanupWithoutRestarting() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source(withHistory: true)
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)), destinations: destinations(app), flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first)
        let profile = try #require(app.model?.coordinator.profileID)
        let file = fixture.directory.appendingPathComponent("History/" + profile.uuidString + ".sqlite")
        let failed = try await withLockedSession(at: file) { await app.undoBrowserImport(batch) }
        #expect(!failed.succeeded)
        #expect(app.workspace?.browserImportBatchIDs?.contains(batch.id) == false)
        #expect(app.browserImportBatches.count == 1)
        let retry = await app.undoBrowserImport(batch)
        #expect(retry.succeeded)
        #expect(app.browserImportBatches.isEmpty)
        let history = try #require(app.history(for: profile))
        #expect(try await history.search("known-visit", limit: 5).isEmpty)
        await fixture.cleanup()
    }

    @Test func failedBackupAndDeletedTargetsNeverApplyAnImport() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source()
        var mapping = destinations(app); mapping["profile"]?.spaceID = UUID()
        #expect(!(await app.importBrowser(doc, selected: doc.initiallySelected, destinations: mapping, flatten: false)).succeeded)
        let before = app.workspace
        let backupPath = try #require(app.backupsDirectory)
        try Data("block directory creation".utf8).write(to: backupPath)
        #expect(!(await app.importBrowser(doc, selected: doc.initiallySelected, destinations: destinations(app), flatten: false)).succeeded)
        #expect(app.workspace == before)
        #expect(app.browserImportBatches.isEmpty)
        await fixture.cleanup()
    }

    @Test func deletingTheOnlyImportedProfileRemovesHistoryJournalAndMarker() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source(withHistory: true)
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)),
            destinations: ["profile": .init(profileName: "Imported Work", spaceName: "Work")], flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first), profile = try #require(batch.profiles.first?.id)
        let file = fixture.directory.appendingPathComponent("History/" + profile.uuidString + ".sqlite")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Imported history was never opened in the browser; no cached store is required.
        await app.deleteProfile(profile)
        #expect(!app.profiles.contains { $0.id == profile })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(app.browserImportBatches.isEmpty)
        #expect(app.workspace?.browserImportBatchIDs?.contains(batch.id) == false)
        let journal = BrowserImportJournal(directory: fixture.directory.appendingPathComponent("BrowserImports"))
        #expect(try await journal.entries().isEmpty)
        #expect(await app.undoBrowserImport(batch).succeeded, "A stale confirmation must not recreate deleted data")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let restarted = EarlyAppDelegate(); restarted.presentWindow = { _ in }; await fixture.start(restarted)
        #expect(restarted.browserImportBatches.isEmpty)
        #expect(restarted.workspace?.browserImportBatchIDs?.contains(batch.id) == false)
        restarted.closeWindow(nil); _ = await restarted.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func deletingOneProfilePrunesAMixedImportAndRemainingUndoSurvivesRestart() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application
        var doc = source(withHistory: true)
        let work = source(withHistory: true).nodes.map { original in
            var node = original; node.id = "work." + node.id; node.parentID = node.parentID.map { "work." + $0 }; node.title = "Work " + node.title
            return node
        }
        doc.nodes += work
        var mapping = destinations(app)
        mapping["work.profile"] = .init(profileName: "Imported Work", spaceName: "Work")
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)), destinations: mapping, flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first), workID = try #require(batch.profiles.first?.id)
        await app.deleteProfile(workID)
        let retained = try #require(app.browserImportBatches.first)
        #expect(retained.id == batch.id && retained.profiles.isEmpty)
        #expect(retained.tabs.allSatisfy { $0.profileID != workID })
        #expect(retained.spaces.allSatisfy { $0.profileID != workID })
        #expect(retained.historyProfiles == [app.workspace!.defaultProfileID])
        #expect(retained.folders.count == 1)
        let restarted = EarlyAppDelegate(); restarted.presentWindow = { _ in }; await fixture.start(restarted)
        let recovered = try #require(restarted.browserImportBatches.first)
        #expect(recovered == retained)
        let history = try #require(restarted.history(for: restarted.workspace!.defaultProfileID))
        let url = URL(string: "https://example.invalid/later")!
        try await history.record(url, title: "Later visit", at: Date())
        // Use the stale original confirmation: Undo consults the pruned journal.
        #expect(await restarted.undoBrowserImport(batch).succeeded)
        #expect(try await history.search("known-visit", limit: 5).isEmpty)
        #expect(try await history.search("later", limit: 5).count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("History/" + workID.uuidString + ".sqlite").path))
        restarted.closeWindow(nil); _ = await restarted.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func aFailedProfileDeletionKeepsImportRecordsAndHistory() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source(withHistory: true)
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)),
            destinations: ["profile": .init(profileName: "Imported Work", spaceName: "Work")], flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first), profile = try #require(batch.profiles.first?.id)
        try await withLockedSession(at: fixture.directory.appendingPathComponent("session.sqlite")) { await app.deleteProfile(profile) }
        #expect(app.profileError != nil)
        #expect(app.profiles.contains { $0.id == profile })
        #expect(app.browserImportBatches == [batch])
        let journal = BrowserImportJournal(directory: fixture.directory.appendingPathComponent("BrowserImports"))
        #expect(try await journal.entries().first?.batch == batch)
        let history = HistoryStore(fileURL: fixture.directory.appendingPathComponent("History/" + profile.uuidString + ".sqlite"))
        #expect(try await history.search("known-visit", limit: 5).count == 1)
        await history.close()
        await app.deleteProfile(profile)
        #expect(app.browserImportBatches.isEmpty)
        await fixture.cleanup()
    }

    @Test func startupReconcilesADeletionInterruptedBeforeJournalCleanup() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source(withHistory: true)
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)),
            destinations: ["profile": .init(profileName: "Imported Work", spaceName: "Work")], flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first), profile = try #require(batch.profiles.first?.id)
        var durable = try #require(app.workspace)
        let deleted = durable.deleteProfile(profile); #expect(deleted)
        app.persistence?.enqueue(durable); #expect(await app.persistence?.flush() == true)
        fixture.defaults.set([profile.uuidString], forKey: "pendingProfileCleanup")
        let restarted = EarlyAppDelegate(); restarted.presentWindow = { _ in }; await fixture.start(restarted)
        #expect(restarted.browserImportBatches.isEmpty)
        #expect(restarted.workspace?.browserImportBatchIDs?.contains(batch.id) == false)
        await restarted.retryWebsiteDataCleanup()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("History/" + profile.uuidString + ".sqlite").path))
        restarted.closeWindow(nil); _ = await restarted.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func failedJournalPruningIsVisibleAndFinishesAtNextLaunch() async throws {
        let fixture = Fixture(); await fixture.start()
        let app = fixture.application, doc = source(withHistory: true)
        #expect(await app.importBrowser(doc, selected: Set(doc.nodes.map(\.id)),
            destinations: ["profile": .init(profileName: "Imported Work", spaceName: "Work")], flatten: false).succeeded)
        let batch = try #require(app.browserImportBatches.first), profile = try #require(batch.profiles.first?.id)
        let directory = fixture.directory.appendingPathComponent("BrowserImports")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        await app.deleteProfile(profile)
        #expect(!app.profiles.contains { $0.id == profile })
        #expect(app.browserImportBatches.isEmpty)
        #expect(app.browserImportError?.contains("cleanup is pending") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restarted = EarlyAppDelegate(); restarted.presentWindow = { _ in }; await fixture.start(restarted)
        #expect(restarted.browserImportBatches.isEmpty && restarted.browserImportError == nil)
        #expect(restarted.workspace?.browserImportBatchIDs?.contains(batch.id) == false)
        let journal = BrowserImportJournal(directory: directory)
        #expect(try await journal.entries().isEmpty)
        restarted.closeWindow(nil); _ = await restarted.persistence?.flush()
        await fixture.cleanup()
    }
}
