// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
import zlib
@testable import EarlyCore

struct BrowserImportStorageTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func historyDeduplicatesKnownVisitsAndUndoKeepsNativeVisitsAndTitles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(fileURL: root.appendingPathComponent("history.sqlite"))
        let now = Date(), url = URL(string: "https://example.invalid/history")!
        try await store.record(url, title: "Native title", at: now)
        let row = BrowserImportNode(id: "visit", kind: .history, title: "Imported title", url: url, visitedAt: now.addingTimeInterval(-60))
        let batch = UUID()
        let first = try await store.importVisits([row, row], batchID: batch, now: now)
        let repeated = try await store.importVisits([row], batchID: UUID(), now: now)
        #expect(first == 1 && repeated == 0)
        let before = try await store.search("history", limit: 10)
        #expect(before.first?.visitCount == 2 && before.first?.title == "Native title")
        try await store.record(url, title: "Later native edit", at: now.addingTimeInterval(1))
        try await store.undoBrowserImport(batch)
        let after = try await store.search("history", limit: 10)
        #expect(after.first?.visitCount == 2 && after.first?.title == "Later native edit")
        var old = row; old.visitedAt = now.addingTimeInterval(-366 * 86400)
        #expect(try await store.importVisits([old], batchID: UUID(), now: now) == 0)
        await store.close()
    }
    @Test func recoveryRollsBackUncommittedHistoryAndFinishesCommittedUndo() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = BrowserImportJournal(directory: root.appendingPathComponent("BrowserImports"))
        let historyRoot = root.appendingPathComponent("History")
        var workspace = BrowserWorkspace()
        let profile = workspace.defaultProfileID
        let store = HistoryStore(fileURL: historyRoot.appendingPathComponent(profile.uuidString + ".sqlite"))
        let row = BrowserImportNode(id: "visit", kind: .history, title: "Recovery", url: URL(string: "https://example.invalid/recovery")!, visitedAt: Date())
        var batch = BrowserImportBatch(source: "Synthetic"); batch.historyProfiles = [profile]
        try await journal.write(.init(batch: batch, state: .importing))
        _ = try await store.importVisits([row], batchID: batch.id)
        _ = try await journal.recover(workspace: workspace, historyDirectory: historyRoot)
        #expect(try await store.search("recovery", limit: 10).isEmpty)
        #expect(try await journal.entries().isEmpty)

        try await journal.write(.init(batch: batch, state: .importing))
        _ = try await store.importVisits([row], batchID: batch.id)
        workspace.browserImportBatchIDs = [batch.id]
        let recovered = try await journal.recover(workspace: workspace, historyDirectory: historyRoot)
        #expect(recovered.map(\.id) == [batch.id])
        #expect(try await journal.entries().first?.state == .complete)
        #expect(try await store.search("recovery", limit: 10).count == 1)

        try await journal.write(.init(batch: batch, state: .undoing))
        workspace.browserImportBatchIDs = []
        _ = try await journal.recover(workspace: workspace, historyDirectory: historyRoot)
        #expect(try await store.search("recovery", limit: 10).isEmpty)
        #expect(try await journal.entries().isEmpty)
        await store.close()
    }
    @Test func cancelledHistoryTransactionLeavesNoPartialVisits() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(fileURL: root.appendingPathComponent("history.sqlite"))
        let row = BrowserImportNode(id: "visit", kind: .history, title: "Cancelled", url: URL(string: "https://example.invalid/cancelled")!, visitedAt: Date())
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await store.importVisits([row], batchID: UUID())
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled import should throw") } catch is CancellationError {} catch { throw error }
        #expect(try await store.search("cancelled", limit: 10).isEmpty)
        await store.close()
    }
    @Test func sqliteReadersUseCoherentWALSnapshotsAndCorrectEpochs() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
        CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER);
        INSERT INTO urls VALUES(1,'https://example.invalid/epoch','Epoch');
        INSERT INTO visits VALUES(1,1,13437532800000000);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let doc = try BrowserImportFiles.database(file, source: "Chromium", firefox: false)
        #expect(doc.nodes.first { $0.kind == .history }?.visitedAt == Date(timeIntervalSince1970: 1_793_059_200))
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE; INSERT INTO visits VALUES(2,1,13437532800000001);", nil, nil, nil) == SQLITE_OK)
        let snapshot = try BrowserImportFiles.database(file, source: "Chromium", firefox: false)
        #expect(snapshot.nodes.filter { $0.kind == .history }.count == 1)
        #expect(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    }
    @Test func largeFirefoxSourcesCanBeSelectedBeforeApplyingTheWorkspaceTabLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("places.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,parent INTEGER,type INTEGER,title TEXT,fk INTEGER,position INTEGER);
        CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY,place_id INTEGER,visit_date INTEGER);
        INSERT INTO moz_places VALUES(1,'https://example.invalid/bookmark','Page');
        INSERT INTO moz_bookmarks VALUES(1,0,2,'Root',NULL,0);
        WITH RECURSIVE n(id) AS (VALUES(2) UNION ALL SELECT id+1 FROM n WHERE id<20002)
        INSERT INTO moz_bookmarks SELECT id,1,1,'Page '||id,1,id-2 FROM n;
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let doc = try BrowserImportFiles.database(file, source: "Firefox", firefox: true)
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 20001)
        let current = BrowserWorkspace()
        let result = try doc.candidate(into: current, selecting: ["bookmark.2"], destinations: BrowserImportTests().destination(current))
        #expect(result.batch.tabs.count == 1)
        #expect(result.batch.tabs[0].title == "Page 2")
    }

    @Test func rootProfileDiscoveryKeepsIdentitiesAndDoesNotReadStaleEncryptedSessions() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try BrowserImportTests().fixture("ChromiumBookmarks.json")
        for name in ["Default", "Profile 1"] {
            let profile = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try data.write(to: profile.appendingPathComponent("Bookmarks"))
        }
        let state: [String: Any] = ["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("Local State"))
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Sessions_Encrypted"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        try Data("stale-session-deliberately-not-a-valid-format".utf8).write(to: profile.appendingPathComponent("Sessions/Session_1"))
        let doc = try BrowserImportFiles.read(root, source: "Chromium")
        #expect(doc.nodes.filter { $0.kind == .profile }.map(\.title) == ["Personal", "Work"])
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 6)
        #expect(doc.notices.contains { $0.contains("Older cleartext") })
        #expect(try Data(contentsOf: profile.appendingPathComponent("Bookmarks")) == data)
    }

    @Test func safariSelectsBookmarksAndMultipleHistoriesAsOneBatch() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = BrowserImportTests()
        let bookmarks = root.appendingPathComponent("Bookmarks.html"), history = root.appendingPathComponent("History.json")
        try helper.fixture("Bookmarks.html").write(to: bookmarks)
        try helper.fixture("SafariHistory.json").write(to: history)
        let doc = try BrowserImportFiles.readSafariExports([bookmarks, history])
        #expect(doc.source == "Safari")
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 3)
        #expect(doc.nodes.filter { $0.kind == .history }.count == 1)
        #expect(doc.nodes.filter { $0.kind == .profile }.count == 1)
        #expect(doc.initiallySelected.isDisjoint(with: doc.nodes.filter { $0.kind == .history }.map(\.id)))
        let current = BrowserWorkspace()
        let mapping = Dictionary(uniqueKeysWithValues: doc.destinationGroups.map { ($0.id, BrowserImportDestination(profileID: current.defaultProfileID, profileName: "Default", spaceID: current.sessions[0].activeSpaceID, spaceName: "Personal")) })
        let result = try doc.candidate(into: current, selecting: BrowserImportTree(doc).selectableIDs, destinations: mapping)
        #expect(result.batch.tabs.count == 3 && result.workspace.profiles == current.profiles)
        #expect(try Data(contentsOf: bookmarks) == helper.fixture("Bookmarks.html"))
        #expect(try Data(contentsOf: history) == helper.fixture("SafariHistory.json"))
        let other = root.appendingPathComponent("History — Work.json")
        try helper.fixture("SafariHistory.json").write(to: other)
        let multiple = try BrowserImportFiles.readSafariExports([bookmarks, history, other])
        #expect(multiple.nodes.filter { $0.kind == .profile }.count == 2)
        #expect(Set(multiple.nodes.map(\.id)).count == multiple.nodes.count)
    }
    @Test func safariBatchRejectsNonHistoryJSONCredentialsAndUnsupportedFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = root.appendingPathComponent("Bookmarks.html")
        try BrowserImportTests().fixture("Bookmarks.html").write(to: bookmarks)
        for type in ["extensions", "payment_cards"] {
            let file = root.appendingPathComponent(type + ".json")
            try JSONSerialization.data(withJSONObject: ["metadata": ["data_type": type, "schema_version": 1], "items": ["DO-NOT-IMPORT"]]).write(to: file)
            #expect(throws: BrowserImportProblem.self) { try BrowserImportFiles.readSafariExports([bookmarks, file]) }
        }
        let password = root.appendingPathComponent("Passwords.csv")
        try Data("DO-NOT-IMPORT,password,secret".utf8).write(to: password)
        #expect(throws: BrowserImportProblem.self) { try BrowserImportFiles.readSafariExports([bookmarks, password]) }
        #expect(throws: BrowserImportProblem.self) { try BrowserImportFiles.readSafariExports([]) }
        #expect(throws: BrowserImportProblem.self) { try BrowserImportFiles.readSafariExports([bookmarks, bookmarks]) }
    }
    @Test func chromiumHistoryRouteIgnoresBookmarkAndSessionFilesAndKeepsProfileNames() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Default", "Profile 1"] {
            let profile = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            // These must never be opened by the history-only route.
            try Data("not JSON".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
            try Data("not JSON".utf8).write(to: profile.appendingPathComponent("StorableSidebar.json"))
            var db: OpaquePointer?
            #expect(sqlite3_open(profile.appendingPathComponent("History").path, &db) == SQLITE_OK)
            let timestamp = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
            let sql = "CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER); INSERT INTO urls VALUES(1,'https://example.invalid/history','History'); INSERT INTO visits VALUES(1,1,\(timestamp));"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
        }
        let state: [String: Any] = ["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("Local State"))
        let doc = try BrowserImportFiles.readChromiumHistory(root, source: "Chrome")
        #expect(doc.nodes.filter { $0.kind == .profile }.map(\.title) == ["Personal", "Work"])
        #expect(doc.nodes.filter { $0.kind == .history }.count == 2)
        #expect(!doc.nodes.contains { [.bookmark, .pin, .openTab, .folder].contains($0.kind) })
        #expect(!doc.notices.contains { $0.localizedCaseInsensitiveContains("session") })
    }

    @Test func safariZipUsesMetadataWithLocalizedNamesAndIgnoresPasswords() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = BrowserImportTests()
        let zip = archive([("Lesezeichen.html", try helper.fixture("Bookmarks.html")),
                           ("履歴 — Work.json", try helper.fixture("SafariHistory.json")),
                           ("Passwords.csv", Data("DO-NOT-IMPORT,password,secret".utf8))])
        let url = root.appendingPathComponent("Safari.zip"); try zip.write(to: url)
        let doc = try BrowserImportFiles.read(url, source: "Safari")
        #expect(doc.nodes.filter { $0.kind == .history }.count == 1)
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 3)
        #expect(!String(describing: doc).contains("DO-NOT-IMPORT"))
        #expect(doc.nodes.filter { $0.kind == .profile }.count == 2)
    }
    @Test func deflatedSafariExportMatchesStoredExport() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Safari.zip")
        try BrowserImportTests().fixture("Safari-localized.zip").write(to: url)
        let doc = try BrowserImportFiles.read(url, source: "Safari")
        #expect(doc.nodes.filter { $0.kind == .history }.count == 1)
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 3)
        #expect(!String(describing: doc).contains("DO-NOT-IMPORT"))
    }

    @Test func archiveTraversalSymlinksAndCorruptPayloadsAreRejected() throws {
        for name in ["../Bookmarks.html", "/Bookmarks.html", "safe/../../Bookmarks.html", "safe\\Bookmarks.html"] {
            #expect(throws: (any Error).self) { try BrowserImportZIP.entries(archive([(name, Data("<DL></DL>".utf8))])) }
        }
        #expect(throws: (any Error).self) { try BrowserImportZIP.entries(archive([("Bookmarks.html", Data("x".utf8))], attributes: 0xa1ff0000)) }
        var corrupt = archive([("Bookmarks.html", Data("abc".utf8))]); corrupt[44] ^= 1
        #expect(throws: (any Error).self) { try BrowserImportZIP.entries(corrupt) }
    }
    @Test func sourceSymlinksAndExternalEntitiesAreNeverRead() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try Data("SECRET-SHOULD-STAY-OUTSIDE".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Bookmarks"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try BrowserImportFiles.read(profile, source: "Test") }
        let html = "<!DOCTYPE html [<!ENTITY secret SYSTEM '\(outside.absoluteString)'>]><html><body><dl><dt><a href='https://example.invalid/'>&secret;</a></dt></dl></body></html>"
        let doc = try BrowserImportReaders.bookmarksHTML(Data(html.utf8), name: "Test")
        #expect(!String(describing: doc).contains("SECRET-SHOULD-STAY-OUTSIDE"))
    }
    @Test func largeImportsAreBulkRecordsWithNoSelectionAndRemainPortable() throws {
        var doc = BrowserImportDocument(source: "Large", nodes: [.init(id: "profile", kind: .profile, title: "Large")])
        for index in 0..<5000 {
            doc.nodes.append(.init(id: "item.\(index)", parentID: "profile", kind: .bookmark, title: "Page \(index)", url: URL(string: "https://example.invalid/\(index)")!))
        }
        let workspace = BrowserWorkspace()
        let result = try doc.candidate(into: workspace, selecting: doc.initiallySelected, destinations: BrowserImportTests().destination(workspace))
        #expect(result.batch.tabs.count == 5000)
        #expect(result.workspace.sessions[0].selectionBySpace.isEmpty)
        #expect(result.batch.tabs.allSatisfy { !$0.isOpen })
        _ = try EarlyStateArchive.decode(EarlyStateArchive(workspace: result.workspace, settings: nil).encoded())
        #expect(try result.batch.undo(in: result.workspace).workspace.sessions[0].tabs.isEmpty)
    }

    /// Synthetic stored ZIP records; no external archiver or executable content.
    func archive(_ files: [(String, Data)], attributes: UInt32 = 0) -> Data {
        func le(_ value: UInt32, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var payload = Data(), central = Data()
        for (name, data) in files {
            let name = Data(name.utf8), offset = UInt32(payload.count)
            let crc = UInt32(data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            payload += le(0x04034b50,4) + le(20,2) + le(0x800,2) + le(0,2) + le(0,4) + le(crc,4)
            payload += le(UInt32(data.count),4) + le(UInt32(data.count),4) + le(UInt32(name.count),2) + le(0,2) + name + data
            central += le(0x02014b50,4) + le(0x0314,2) + le(20,2) + le(0x800,2) + le(0,2) + le(0,4) + le(crc,4)
            central += le(UInt32(data.count),4) + le(UInt32(data.count),4) + le(UInt32(name.count),2) + le(0,2) + le(0,2) + le(0,2) + le(0,2) + le(attributes,4) + le(offset,4) + name
        }
        let offset = UInt32(payload.count), count = UInt32(files.count)
        return payload + central + le(0x06054b50,4) + le(0,2) + le(0,2) + le(count,2) + le(count,2) + le(UInt32(central.count),4) + le(offset,4) + le(0,2)
    }
}
