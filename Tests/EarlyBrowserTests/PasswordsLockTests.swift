// SPDX-License-Identifier: MPL-2.0

import AppKit
import Testing
@testable import EarlyBrowser

/// Controlled authentication replies; no system prompts or UI automation.
@Suite(.serialized) @MainActor
struct PasswordsLockTests {
    @MainActor private final class Replies {
        var waiting: [CheckedContinuation<Bool, Never>?] = []
        func authenticate(_ reason: String) async -> Bool {
            await withCheckedContinuation { waiting.append($0) }
        }
        func answer(_ index: Int, _ success: Bool) {
            let reply = waiting[index]
            waiting[index] = nil
            reply?.resume(returning: success)
        }
        func finish() {
            for index in waiting.indices { answer(index, false) }
        }
        func waitFor(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while waiting.count < count {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @Test(arguments: [false, true])
    func lockingRejectsAnOldUnlockWithoutDisturbingItsReplacement(oldFinishesFirst: Bool) async throws {
        let lock = PasswordsLock(), replies = Replies()
        lock.authenticate = { await replies.authenticate($0) }
        defer { replies.finish(); lock.lock() }
        let old = Task { await lock.unlock() }
        try await replies.waitFor(1)
        lock.lock() // Also called when Passwords disappears.
        let current = Task { await lock.unlock() }
        try await replies.waitFor(2)
        if oldFinishesFirst {
            replies.answer(0, true)
            #expect(await old.value == false)
            #expect(!lock.isUnlocked)
        }
        replies.answer(1, true)
        #expect(await current.value)
        #expect(lock.isUnlocked)
        if !oldFinishesFirst {
            // The obsolete pending reply must no longer suppress background locking.
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            #expect(!lock.isUnlocked)
            replies.answer(0, true)
            #expect(await old.value == false)
            #expect(!lock.isUnlocked)
        }
    }

    @Test func aNewerFailedAttemptRejectsAnOlderSuccess() async throws {
        let lock = PasswordsLock(), replies = Replies()
        lock.authenticate = { await replies.authenticate($0) }
        defer { replies.finish(); lock.lock() }
        let old = Task { await lock.unlock() }
        try await replies.waitFor(1)
        let newer = Task { await lock.unlock() }
        try await replies.waitFor(2)
        replies.answer(1, false)
        #expect(await newer.value == false)
        replies.answer(0, true)
        #expect(await old.value == false)
        #expect(!lock.isUnlocked)
    }

    @Test func lockingRejectsALateConfirmation() async throws {
        let lock = PasswordsLock(), replies = Replies()
        lock.authenticate = { _ in true }
        #expect(await lock.unlock())
        lock.authenticate = { await replies.authenticate($0) }
        defer { replies.finish(); lock.lock() }
        let confirmation = Task { await lock.confirm("export your saved passwords") }
        try await replies.waitFor(1)
        lock.lock()
        replies.answer(0, true)
        #expect(await confirmation.value == false)
        #expect(!lock.isUnlocked)
    }

    @Test func currentAuthenticationAndKeychainPromptsMayTemporarilyDeactivateTheApp() async throws {
        let lock = PasswordsLock(), replies = Replies()
        lock.authenticate = { await replies.authenticate($0) }
        defer { replies.finish(); lock.lock() }
        let unlocking = Task { await lock.unlock() }
        try await replies.waitFor(1)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        replies.answer(0, true)
        #expect(await unlocking.value)
        #expect(lock.isUnlocked)
        await lock.prompting {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        }
        #expect(lock.isUnlocked)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!lock.isUnlocked)
    }
}
