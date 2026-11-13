// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
@testable import EarlyCore

@Suite
struct HistoryCleanupTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyHistoryCleanup-\(UUID())", isDirectory: true)
        var file: URL { root.appendingPathComponent("history.sqlite") }
        var wal: URL { URL(fileURLWithPath: file.path + "-wal") }
        var walBytes: Data { get throws { try Data(contentsOf: wal) } }
    }

    /// An independent SQLite connection, like a reader holding an older snapshot.
    private final class Connection {
        private var db: OpaquePointer?
        init(_ file: URL, readOnly: Bool = true) throws {
            let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
            let result = sqlite3_open_v2(file.path, &db, flags, nil)
            if result != SQLITE_OK { close() }
            try #require(result == SQLITE_OK)
        }
        deinit { close() }
        func close() { if let db { sqlite3_close(db) }; db = nil }
        func execute(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        func integer(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
        func beginReading() throws { try execute("BEGIN; SELECT COUNT(*) FROM visits;") }
        func endReading() throws { try execute("COMMIT;") }
    }

    enum Deletion: CaseIterable { case visits, pages, since, all, before, undoImport }

    @Test(arguments: Deletion.allCases)
    func explicitDeletionRemovesOldLogCopiesWhileTheStoreStaysOpen(deletion: Deletion) async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let removed = URL(string: "https://history.invalid/removed-\(UUID())")!
        let kept = URL(string: "https://history.invalid/kept")!
        let targetDate = deletion == .before ? start : start.addingTimeInterval(20)
        let keptDate = deletion == .before ? start.addingTimeInterval(20) : start
        let batch = UUID()
        try await store.record(kept, title: "Keep", at: keptDate)
        if deletion == .undoImport {
            let row = BrowserImportNode(id: "visit", kind: .history, title: "Remove", url: removed, visitedAt: targetDate)
            #expect(try await store.importVisits([row], batchID: batch, now: targetDate) == 1)
        } else { try await store.record(removed, title: "Remove", at: targetDate) }
        let marker = Data(removed.absoluteString.utf8)
        #expect(try fixture.walBytes.range(of: marker) != nil, "The test starts with an old copy in the WAL")
        switch deletion {
        case .visits:
            let visit = try #require(try await store.visits().first { $0.url == removed })
            try await store.deleteVisits([visit.id])
        case .pages: try await store.deletePages([removed])
        case .since: try await store.deleteVisits(since: start.addingTimeInterval(10))
        case .all: try await store.deleteVisits(since: nil)
        case .before: try await store.deleteVisits(before: start.addingTimeInterval(10))
        case .undoImport: try await store.undoBrowserImport(batch)
        }
        #expect(try await store.visits().map(\.url) == (deletion == .all ? [] : [kept]))
        #expect(try fixture.walBytes.isEmpty, "The live WAL is truncated through SQLite after deletion commits")
        #expect(try Data(contentsOf: fixture.file).range(of: marker) == nil)
        let later = URL(string: "https://history.invalid/later")!
        try await store.record(later, title: "After cleanup", at: start.addingTimeInterval(30))
        #expect(try await store.search("later", limit: 5).map(\.url) == [later])
        #expect(try fixture.walBytes.range(of: marker) == nil, "New visits do not bring back the old log bytes")
    }

    @Test func aBusyReaderDefersCleanupWithoutDelayingDeletionOrNewVisits() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let removed = URL(string: "https://history.invalid/removed-\(UUID())")!, kept = URL(string: "https://history.invalid/kept")!
        try await store.record(removed, title: "Remove", at: start)
        try await store.record(kept, title: "Keep", at: start)
        let reader = try Connection(fixture.file)
        defer { reader.close() }
        try reader.beginReading()
        let began = ContinuousClock.now
        try await store.deletePages([removed])
        #expect(began.duration(to: .now) < .seconds(1.5), "Cleanup does not wait out the two-second busy timeout")
        #expect(try await store.visits().map(\.url) == [kept], "Logical deletion is immediate")
        #expect(try reader.integer("SELECT COUNT(*) FROM visits") == 2, "The existing reader keeps its valid snapshot")
        #expect(await store.checkpointPending)
        #expect(try fixture.walBytes.range(of: Data(removed.absoluteString.utf8)) != nil)
        let retry = try #require(await store.checkpointRetryTask)
        try await store.record(kept, title: "New visit", at: start.addingTimeInterval(1))
        #expect(try await store.search("kept", limit: 5).first?.visitCount == 2)
        try reader.endReading()
        await retry.value
        #expect(await store.checkpointPending == false)
        #expect(try fixture.walBytes.isEmpty)
        #expect(try Data(contentsOf: fixture.file).range(of: Data(removed.absoluteString.utf8)) == nil)
        #expect(try await store.visits().count == 2, "Checkpointing preserves the newer visits")
    }

    @Test func retriesAreBoundedAndLaterActivityFinishesThePendingCleanup() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        try await store.record(URL(string: "https://history.invalid/remove")!, title: "Remove", at: start)
        let reader = try Connection(fixture.file)
        defer { reader.close() }
        try reader.beginReading()
        try await store.deleteVisits(since: nil)
        let retry = try #require(await store.checkpointRetryTask)
        await retry.value
        #expect(await store.checkpointRetryTask == nil, "The worker stops after its bounded retry burst")
        #expect(await store.checkpointPending, "An exhausted retry budget does not lose the request")
        #expect(try await store.visits().isEmpty)
        try reader.endReading()
        try await Task.sleep(for: .milliseconds(1100)) // The activity-triggered retry has a one-second cooldown.
        #expect(try await store.visits().isEmpty)
        #expect(await store.checkpointPending == false)
        #expect(try fixture.walBytes.isEmpty)
        try await store.record(URL(string: "https://history.invalid/new")!, title: "New", at: start)
        #expect(try fixture.walBytes.isEmpty == false, "Ordinary browsing does not keep truncating the log")
    }

    @Test func reopeningFinishesCleanupThatWasBlockedWhenTheConnectionClosed() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        let reopened = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); await reopened.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        try await store.record(URL(string: "https://history.invalid/remove")!, title: "Remove", at: start)
        let reader = try Connection(fixture.file)
        defer { reader.close() }
        try reader.beginReading()
        try await store.deleteVisits(since: nil)
        let previousRetry = try #require(await store.checkpointRetryTask)
        await store.close()
        await previousRetry.value
        #expect(await store.checkpointRetryTask == nil)
        #expect(try fixture.walBytes.isEmpty == false)
        #expect(try await reopened.visits().isEmpty)
        #expect(await reopened.checkpointPending)
        let retry = try #require(await reopened.checkpointRetryTask)
        try reader.endReading()
        await retry.value
        #expect(await reopened.checkpointPending == false)
        #expect(try fixture.walBytes.isEmpty)
    }

    @Test func deletingTheProfileCancelsCleanupWithoutRecreatingItsDatabase() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await store.record(URL(string: "https://history.invalid/remove")!, title: "Remove", at: start)
        let reader = try Connection(fixture.file)
        defer { reader.close() }
        try reader.beginReading()
        try await store.deleteVisits(since: nil)
        let retry = try #require(await store.checkpointRetryTask)
        reader.close()
        try await store.removeFile()
        await retry.value
        #expect(await store.checkpointRetryTask == nil)
        await #expect(throws: SessionError.self) { try await store.visits() }
        for suffix in ["", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: fixture.file.path + suffix)) }
    }

    @Test func failedDeletionRollsBackWithoutSchedulingLogCleanup() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let url = URL(string: "https://history.invalid/keep-after-failure")!
        try await store.record(url, title: "Keep", at: start)
        let other = try Connection(fixture.file, readOnly: false)
        defer { other.close() }
        try other.execute("CREATE TRIGGER fail_delete BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT, 'Synthetic deletion failure'); END;")
        await #expect(throws: SessionError.self) { try await store.deleteVisits(since: nil) }
        #expect(try await store.visits().map(\.url) == [url])
        #expect(await store.checkpointPending == false)
        #expect(await store.checkpointRetryTask == nil)
        #expect(try fixture.walBytes.range(of: Data(url.absoluteString.utf8)) != nil)
    }

    @Test func clearingManyPagesZerosTheirFreedSpaceWithoutRewritingTheDatabase() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let marker = "deleted-history-\(UUID())"
        for index in 0..<64 {
            let url = URL(string: "https://history.invalid/\(marker)/\(index)/" + String(repeating: "x", count: 2600))!
            try await store.record(url, title: marker, at: start)
        }
        let other = try Connection(fixture.file, readOnly: false)
        defer { other.close() }
        try other.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        #expect(try Data(contentsOf: fixture.file).range(of: Data(marker.utf8)) != nil)
        try await store.deleteVisits(since: nil)
        #expect(try await store.visits().isEmpty)
        #expect(try fixture.walBytes.isEmpty)
        #expect(try Data(contentsOf: fixture.file).range(of: Data(marker.utf8)) == nil)
        #expect(try other.integer("PRAGMA freelist_count") > 0, "The database keeps reusable pages; no VACUUM is needed")
    }

    @Test func partialClearsPreserveImportDeduplicationAndUndoKeepsLaterNativeVisits() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let kept = BrowserImportNode(id: "kept", kind: .history, title: "Imported", url: URL(string: "https://history.invalid/kept")!, visitedAt: start)
        let removed = BrowserImportNode(id: "removed", kind: .history, title: "Remove", url: URL(string: "https://history.invalid/removed")!, visitedAt: start.addingTimeInterval(20))
        let batch = UUID(), now = start.addingTimeInterval(30)
        #expect(try await store.importVisits([kept, removed], batchID: batch, now: now) == 2)
        try await store.deleteVisits(since: start.addingTimeInterval(10))
        #expect(try fixture.walBytes.isEmpty)
        #expect(try await store.importVisits([kept], batchID: UUID(), now: now) == 0)
        try await store.record(kept.url!, title: "Native", at: now)
        try await store.undoBrowserImport(batch)
        let page = try #require(try await store.search("kept", limit: 1).first)
        #expect(page.visitCount == 1 && page.lastVisit == now && page.title == "Native")
        #expect(try fixture.walBytes.isEmpty)
    }

    @Test func routineRetentionDoesNotAddACheckpointToNormalBrowsing() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var date: Date
            init(_ date: Date) { self.date = date }
            func read() -> Date { lock.withLock { date } }
            func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
        }
        let fixture = Fixture(), clock = Clock(start)
        let store = HistoryStore(fileURL: fixture.file, retention: 30, now: clock.read)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        for index in 0..<200 {
            try await store.record(URL(string: "https://history.invalid/page-\(index)")!, title: "Page", at: start.addingTimeInterval(Double(index)))
        }
        clock.advance(199)
        #expect(try await store.visits().count == 31)
        #expect(try fixture.walBytes.isEmpty == false)
        #expect(await store.checkpointPending == false)
        #expect(await store.checkpointRetryTask == nil)
    }
}
