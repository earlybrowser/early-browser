// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct PasswordVaultSavingTests {
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let gates: [Int: DispatchSemaphore]
        private let failures: Set<Int>
        private var count = 0, active = 0, peak = 0
        private var usedMainThread = false

        init(paused: Set<Int>, failures: Set<Int> = []) {
            gates = Dictionary(uniqueKeysWithValues: paused.map { ($0, DispatchSemaphore(value: 0)) })
            self.failures = failures
        }
        var writes: Int { lock.withLock { count } }
        var maximumActive: Int { lock.withLock { peak } }
        var ranOnMain: Bool { lock.withLock { usedMainThread } }
        func release(_ index: Int) { gates[index]?.signal() }
        func releaseAll() { gates.values.forEach { $0.signal() } }
        func write(_ data: Data, to file: URL) throws {
            let index = lock.withLock {
                count += 1; active += 1; peak = max(peak, active)
                usedMainThread = usedMainThread || Thread.isMainThread
                return count
            }
            defer { lock.withLock { active -= 1 } }
            if let gate = gates[index], gate.wait(timeout: .now() + 10) != .success { throw CocoaError(.fileWriteUnknown) }
            if failures.contains(index) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "The controlled operation reached its next step")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "EarlyVaultSaving-\(UUID())/profile.vault")
    }

    @Test func flushIncludesEditsAndDraftsArrivingDuringAWriteWithoutQueuingEverySnapshot() async throws {
        let file = file(), key = MemoryVaultKey(), writer = Writer(paused: [1, 2])
        let vault = PasswordVault(fileURL: file, key: key)
        vault.writeFile = writer.write
        defer { writer.releaseAll(); Task { _ = await vault.flush(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "first", password: "one")
        try await waitUntil { writer.writes == 1 }
        var started = false, finished = false
        let flush = Task { started = true; let saved = await vault.flush(); finished = true; return saved }
        try await waitUntil { started }
        for index in 0..<250 { vault.save(origin: "https://example.com", username: "user-\(index)", password: "synthetic") }
        vault.saveDraft(origin: "https://new.example", username: "new", password: "generated")
        writer.release(1)
        try await waitUntil { writer.writes == 2 }
        #expect(!finished, "The first success must not release flush while the latest snapshot is still writing")
        let old = PasswordVault(fileURL: file, key: key)
        #expect(await old.load())
        #expect(old.logins.count == 1 && old.drafts.isEmpty)
        writer.release(2)
        #expect(await flush.value)
        #expect(writer.writes == 2 && writer.maximumActive == 1 && !writer.ranOnMain)
        let reopened = PasswordVault(fileURL: file, key: key)
        #expect(await reopened.load())
        #expect(reopened.logins.count == 251 && reopened.drafts.map(\.password) == ["generated"])
    }

    @Test func aNewerFailureIsReportedAndAnOlderRetrySuccessCannotHidePendingChanges() async throws {
        let file = file(), key = MemoryVaultKey(), writer = Writer(paused: [1, 2, 3, 4], failures: [2])
        let vault = PasswordVault(fileURL: file, key: key)
        vault.writeFile = writer.write
        defer { writer.releaseAll(); Task { _ = await vault.flush(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "first", password: "one")
        try await waitUntil { writer.writes == 1 }
        let flush = Task { await vault.flush() }
        vault.save(origin: "https://example.com", username: "second", password: "two")
        writer.release(1)
        try await waitUntil { writer.writes == 2 }
        writer.release(2)
        #expect(await flush.value == false)
        #expect(vault.saveError?.contains("couldn’t be written") == true)
        #expect(vault.logins.count == 2)
        vault.retrySaving()
        try await waitUntil { writer.writes == 3 }
        vault.save(origin: "https://example.com", username: "third", password: "three")
        let retry = Task { await vault.flush() }
        writer.release(3)
        try await waitUntil { writer.writes == 4 }
        #expect(vault.saveError != nil, "A successful older retry does not declare the current changes saved")
        writer.release(4)
        #expect(await retry.value && vault.saveError == nil)
        let reopened = PasswordVault(fileURL: file, key: key)
        #expect(await reopened.load())
        #expect(reopened.logins.count == 3 && writer.maximumActive == 1)
    }

    @Test func removalDrainsTheActiveWriteAndDiscardsThePendingSnapshot() async throws {
        let file = file(), key = MemoryVaultKey(), writer = Writer(paused: [1])
        let vault = PasswordVault(fileURL: file, key: key)
        vault.writeFile = writer.write
        defer { writer.releaseAll(); Task { _ = await vault.flush(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "first", password: "one")
        try await waitUntil { writer.writes == 1 }
        vault.save(origin: "https://example.com", username: "second", password: "two")
        let flush = Task { await vault.flush() }
        var removed = false
        let deletion = Task { try await vault.removeAll(); removed = true }
        try await waitUntil { !vault.isReady }
        #expect(!removed && key.key != nil)
        writer.release(1)
        try await deletion.value
        #expect(await flush.value)
        #expect(writer.writes == 1 && key.key == nil && !FileManager.default.fileExists(atPath: file.path))
        #expect(vault.logins.isEmpty && vault.saveError == nil)
    }
}
