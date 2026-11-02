// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
@testable import EarlyCore

@Suite(.serialized)
struct HistoryImportPerformanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyHistoryImport-\(UUID())", isDirectory: true)
        var file: URL { root.appendingPathComponent("history.sqlite") }
    }

    private final class Connection {
        private var db: OpaquePointer?
        init(_ file: URL) throws {
            let result = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            if result != SQLITE_OK { sqlite3_close(db); db = nil }
            try #require(result == SQLITE_OK)
            sqlite3_busy_timeout(db, 0)
        }
        deinit { sqlite3_close(db) }
        func execute(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        func integer(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
        func canAcquireWriteLock() throws -> Bool {
            let result = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { return false }
            try #require(result == SQLITE_OK)
            try execute("ROLLBACK")
            return true
        }
    }

    private func row(_ id: String, url: String = "https://history.invalid/page", title: String = "Imported", secondsAgo: Double = 0) -> BrowserImportNode {
        .init(id: id, kind: .history, title: title, url: URL(string: url)!, visitedAt: now.addingTimeInterval(-secondsAgo))
    }

    @Test(arguments: [1, 1000])
    func repeatedCommandsArePreparedOncePerBatchRegardlessOfVisitCount(_ count: Int) async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let records = (0..<count).map { row("row.\($0)", secondsAgo: Double($0)) }
        #expect(try await store.importVisits(records, batchID: UUID(), now: now) == count)
        #expect(await store.importBatchStatementCount == 5)
        #expect(try await store.search("history", limit: 10).first?.visitCount == count)
        #expect(try await store.importVisits(records, batchID: UUID(), now: now) == 0)
        #expect(await store.importBatchStatementCount == 5, "Duplicate-only batches keep an indexed, bounded lookup")
        let extra = row("extra", url: "https://history.invalid/another", title: "Another", secondsAgo: 0.5)
        #expect(try await store.importVisits([extra], batchID: UUID(), now: now) == 1)
        #expect(try await store.search("another", limit: 10).first?.title == "Another")
    }

    @Test func importsKeepOriginalTitlesRealTimestampsRetentionAndLaterNativeVisits() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file, retention: 3600)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let existing = URL(string: "https://history.invalid/native")!
        try await store.record(existing, title: "Native title", at: now)
        let existingVisit = row("native", url: existing.absoluteString, title: "Do not overwrite", secondsAgo: 10)
        let first = row("first", title: "  First\n title  ", secondsAgo: 30)
        let second = row("second", title: "Later imported title", secondsAgo: 20)
        var duplicate = second; duplicate.id = "copy"
        var missing = row("missing"); missing.visitedAt = nil
        var nonfinite = row("nan"); nonfinite.visitedAt = Date(timeIntervalSince1970: .nan)
        let records = [existingVisit, first, second, duplicate, row("old", secondsAgo: 3601),
                       row("future", secondsAgo: -301), row("local", url: "file:///private/local.html"), missing, nonfinite]
        let batch = UUID()
        #expect(try await store.importVisits(records, batchID: batch, now: now) == 3)
        let imported = try #require(try await store.search("history.invalid/page", limit: 5).first)
        #expect(imported.title == "First  title")
        #expect(imported.visitCount == 2 && imported.lastVisit == now.addingTimeInterval(-20))
        #expect(try await store.visits(matching: "history.invalid/page").map(\.visitedAt) == [now.addingTimeInterval(-20), now.addingTimeInterval(-30)])
        #expect(try await store.search("native", limit: 5).first?.title == "Native title")
        #expect(try await store.importVisits(Array(records.reversed()), batchID: UUID(), now: now) == 0)
        try await store.record(existing, title: "Native edit after import", at: now.addingTimeInterval(1))
        try await store.undoBrowserImport(batch)
        #expect(try await store.search("history.invalid/page", limit: 5).isEmpty)
        let native = try #require(try await store.search("native", limit: 5).first)
        #expect(native.title == "Native edit after import" && native.visitCount == 2)
        #expect(native.lastVisit == now.addingTimeInterval(1))
        #expect(try await store.importVisits([first, second], batchID: UUID(), now: now) == 2, "Undo removes the corresponding source-visit identities")
    }

    @Test func aMidBatchDatabaseFailureRollsBackEveryWriteAndLeavesTheNextBatchUsable() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let original = URL(string: "https://history.invalid/native")!
        try await store.record(original, title: "Native", at: now)
        let connection = try Connection(fixture.file)
        try connection.execute("""
            CREATE TRIGGER reject_import BEFORE INSERT ON visits
            WHEN NEW.visited_at = 1799999999
            BEGIN SELECT RAISE(ABORT, 'Injected history-import failure'); END;
            """)
        let records = [row("one", url: "https://history.invalid/one", secondsAgo: 2),
                       row("two", url: "https://history.invalid/two", secondsAgo: 1)]
        let batch = UUID()
        do {
            _ = try await store.importVisits(records, batchID: batch, now: now)
            Issue.record("The second visit must fail after the first has been staged")
        } catch is SessionError {}
        #expect(try await store.visits().map(\.url) == [original])
        #expect(try connection.integer("SELECT COUNT(*) FROM pages") == 1)
        #expect(try connection.integer("SELECT COUNT(*) FROM browser_import_visits") == 0)
        try connection.execute("DROP TRIGGER reject_import")
        #expect(try await store.importVisits(records, batchID: batch, now: now) == 2)
        #expect(try await store.search("history", limit: 10).reduce(0) { $0 + $1.visitCount } == 3)
        try await store.undoBrowserImport(batch)
        #expect(try await store.visits().map(\.url) == [original])
    }

    @Test func cancellationDuringTheWriteTransactionLeavesNoPartialVisitsOrSourceTracking() async throws {
        let fixture = Fixture(), store = HistoryStore(fileURL: fixture.file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let original = URL(string: "https://history.invalid/native")!
        try await store.record(original, title: "Native", at: now)
        let connection = try Connection(fixture.file)
        let records = (0..<10_000).map { row("cancel.\($0)", secondsAgo: Double($0 + 1)) }
        let batch = UUID()
        let task = Task { try await store.importVisits(records, batchID: batch, now: now) }
        defer { task.cancel() }
        var observedTransaction = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try !connection.canAcquireWriteLock() { observedTransaction = true; task.cancel(); break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(observedTransaction, "Cancel only after SQLite confirms the import owns its write transaction")
        do { _ = try await task.value; Issue.record("A cancelled import must roll back") }
        catch is CancellationError {}
        #expect(try await store.visits().map(\.url) == [original])
        #expect(try connection.integer("SELECT COUNT(*) FROM browser_import_visits") == 0)
        #expect(try connection.integer("SELECT COUNT(*) FROM pages") == 1)
        #expect(try await store.importVisits([records[0]], batchID: batch, now: now) == 1)
    }
}
