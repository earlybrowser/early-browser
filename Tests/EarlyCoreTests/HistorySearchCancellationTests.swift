// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
@testable import EarlyCore

@Suite(.serialized)
struct HistorySearchCancellationTests {
    private final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var calls = 0
        var started: Bool { lock.withLock { calls > 0 } }
        func observe() {
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first { _ = semaphore.wait(timeout: .now() + 10) }
        }
        func release() { semaphore.signal() }
    }
    private func wait(_ gate: ProgressGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.started {
            try #require(ContinuousClock.now < deadline, "The real SQLite scan must reach its progress callback")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EarlySearchCancel-\(UUID())/history.sqlite")
    }
    private func seed(_ file: URL, store: HistoryStore) async throws {
        try await store.record(URL(string: "https://seed.invalid")!, title: "Seed", at: Date())
        var db: OpaquePointer?
        try #require(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<30000)
            INSERT INTO pages(url,title,visit_count,last_visit)
            SELECT 'https://history.invalid/'||i,'A synthetic title '||i,1,1800000000+i FROM n;
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func alreadyCancelledSearchDoesNotOpenTheDatabaseEvenForAnEmptyQuery() async throws {
        for query in ["history", ""] {
            let file = file(), store = HistoryStore(fileURL: file)
            defer { Task { await store.close(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.search(query, limit: 10)
            }
            do { _ = try await task.value; Issue.record("A cancelled request must not search") }
            catch { #expect(error is CancellationError) }
            #expect(await store.searchStatementCount == 0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func anActiveCancelledScanStopsAndTheNextQueryAndWriteStillWork() async throws {
        let file = file(), gate = ProgressGate(), store = HistoryStore(fileURL: file, searchProgress: gate.observe)
        defer { gate.release(); Task { await store.close(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        try await seed(file, store: store)
        let task = Task.detached { try await store.search("not present anywhere", limit: 500) }
        try await wait(gate)
        task.cancel(); gate.release()
        do { _ = try await task.value; Issue.record("The cancelled SQLite scan must stop") }
        catch { #expect(error is CancellationError) }
        #expect(await store.searchStatementCount == 1)
        #expect(try await store.search("synthetic", limit: 3).count == 3)
        let next = URL(string: "https://after-cancellation.invalid")!
        try await store.record(next, title: "After cancellation", at: Date())
        #expect(try await store.search("after-cancellation", limit: 3).first?.url == next)
    }

    @Test func cancellationWhileQueuedNeverInstallsAHandlerForTheNewerQuery() async throws {
        let file = file(), gate = ProgressGate(), store = HistoryStore(fileURL: file, searchProgress: gate.observe)
        defer { gate.release(); Task { await store.close(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        try await seed(file, store: store)
        let first = Task.detached { try await store.search("synthetic", limit: 2) }
        try await wait(gate)
        let queued = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.search("old query", limit: 10)
        }
        gate.release()
        #expect(try await first.value.count == 2)
        do { _ = try await queued.value; Issue.record("Queued cancellation must be honored before SQL starts") }
        catch { #expect(error is CancellationError) }
        #expect(await store.searchStatementCount == 1)
        #expect(try await store.search("history.invalid/3", limit: 1).first != nil)
        #expect(await store.searchStatementCount == 2)
    }

    @Test func substringEscapingUnicodeAndRankingRemainUnchanged() async throws {
        let file = file(), store = HistoryStore(fileURL: file)
        defer { Task { await store.close(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        let first = URL(string: "https://example.invalid/a%25_b")!, second = URL(string: "https://example.invalid/other")!
        let date = Date()
        try await store.record(first, title: "Café Swift 100%_ \\ Guide", at: date)
        try await store.record(second, title: "Swift guide", at: date.addingTimeInterval(1))
        try await store.record(first, title: nil, at: date.addingTimeInterval(2))
        for query in ["Café Swift", "100%_", "\\", "a%25_b"] {
            #expect(try await store.search(query, limit: 10).map(\.url) == [first])
        }
        #expect(try await store.search("Swift guide", limit: 10).map(\.url) == [first, second])
        #expect(try await store.search("missing", limit: 10).isEmpty)
        #expect(try await store.search("swift", limit: 0).isEmpty)
    }
}
