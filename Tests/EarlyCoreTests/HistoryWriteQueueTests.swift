// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite(.serialized) @MainActor struct HistoryWriteQueueTests {
    @Test(arguments: [false, true])
    func clearingFailedWritesPreventsTheirReturnAndPreservesWritesOutsideTheRange(clearAll: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyHistoryWrites-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "blocked")
        try Data().write(to: blocker)
        let store = HistoryStore(fileURL: blocker.appending(path: "history.sqlite"))
        let old = URL(string: "https://history.invalid/older")!, cleared = URL(string: "https://history.invalid/cleared")!
        let date = Date(), earlier = date.addingTimeInterval(-7200)
        store.queueVisit(old, title: "Older", at: earlier)
        store.queueTitle(old, title: "Older title", visitedAt: earlier)
        store.queueVisit(cleared, title: "Removed", at: date)
        store.queueTitle(cleared, title: "Removed title", visitedAt: date)
        #expect(await store.pendingWrites.drain() != nil)
        try FileManager.default.removeItem(at: blocker)
        try await store.queueDeletion(.since(clearAll ? nil : date.addingTimeInterval(-3600))).value.get()
        store.retryPendingWrites()
        #expect(await store.pendingWrites.drain() == nil)
        #expect(try await store.visits().map(\.title) == (clearAll ? [] : ["Older title"]))
        store.queueVisit(cleared, title: "New visit after clearing", at: Date())
        #expect(await store.pendingWrites.drain() == nil)
        #expect(try await store.visits().filter { $0.url == cleared }.map(\.title) == ["New visit after clearing"])
        await store.close()
    }

    @Test func queuedPageRemovalDropsFailedWritesOnlyForThosePages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyHistoryWrites-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "blocked")
        try Data().write(to: blocker)
        let store = HistoryStore(fileURL: blocker.appending(path: "history.sqlite"))
        let removed = URL(string: "https://history.invalid/removed")!, kept = URL(string: "https://history.invalid/kept")!
        store.queueVisit(removed, title: "Removed", at: Date())
        store.queueVisit(kept, title: "Kept", at: Date())
        #expect(await store.pendingWrites.drain() != nil)
        try FileManager.default.removeItem(at: blocker)
        try await store.queueDeletion(.pages([removed])).value.get()
        store.retryPendingWrites()
        #expect(await store.pendingWrites.drain() == nil)
        #expect(try await store.visits().map(\.url) == [kept])
        try await store.removeFile()
        store.queueVisit(removed, title: "Late callback", at: Date())
        #expect(await store.pendingWrites.drain() != nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
