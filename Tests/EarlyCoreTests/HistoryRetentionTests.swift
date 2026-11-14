// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite struct HistoryRetentionTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        func read() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
    }

    @Test func shortSessionsExpireHistoryAndKeepImportIdentitiesAndBoundaryVisits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "history.sqlite"), clock = Clock(), batch = UUID()
        let old = URL(string: "https://retention.invalid/old")!, boundary = URL(string: "https://retention.invalid/boundary")!
        let initial = HistoryStore(fileURL: file, retention: 60, now: clock.read)
        try await initial.record(old, title: "Expired", at: clock.read().addingTimeInterval(-59))
        let imported = BrowserImportNode(id: "imported", kind: .history, title: "Boundary", url: boundary,
                                        visitedAt: clock.read())
        #expect(try await initial.importVisits([imported], batchID: batch, now: clock.read()) == 1)
        await initial.close()
        clock.advance(60)

        for _ in 0..<10 {
            let store = HistoryStore(fileURL: file, retention: 60, now: clock.read)
            #expect(try await store.visits().map(\.url) == [boundary], "First use expires old visits even without new browsing")
            #expect(try await store.importVisits([imported], batchID: batch, now: clock.read()) == 0,
                    "Retention preserves the exact boundary and surviving import deduplication")
            #expect(await store.retentionPassCount == 1, "Reads and imports share one maintenance deadline")
            await store.close()
        }
        let store = HistoryStore(fileURL: file, retention: 60, now: clock.read)
        try await store.undoBrowserImport(batch)
        #expect(try await store.visits().isEmpty, "Undo still owns the retained imported visit")
        await store.close()
    }

    @Test func elapsedTimeExpiresHistoryWithoutTwoHundredWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), store = HistoryStore(fileURL: root.appending(path: "history.sqlite"), retention: 60, now: clock.read)
        let url = URL(string: "https://retention.invalid/page")!
        try await store.record(url, title: "First", at: clock.read())
        for _ in 0..<20 { _ = try await store.visits() }
        #expect(await store.retentionPassCount == 1)
        clock.advance(61)
        #expect(try await store.visits().isEmpty)
        #expect(await store.retentionPassCount == 2)
        try await store.record(url, title: "New", at: clock.read())
        #expect(try await store.visits().count == 1)
        #expect(await store.retentionPassCount == 2)
        await store.close()
    }

    @Test func anIdleOpenStoreExpiresAndClosingStopsItsTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyRetention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), file = root.appending(path: "history.sqlite")
        let store = HistoryStore(fileURL: file, retention: 1, now: clock.read)
        try await store.record(URL(string: "https://retention.invalid/idle")!, title: "Idle", at: clock.read())
        clock.advance(2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        // Reading the diagnostic does not open the connection or run expiry.
        while await store.retentionPassCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await store.retentionPassCount == 2, "The timer runs without queries or visits")
        #expect(try await store.visits().isEmpty)
        await store.close()
        clock.advance(2)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await store.retentionPassCount == 2, "Closing cancels idle work")
    }
}
