// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security
import Testing
@testable import EarlyCore

@Suite @MainActor
struct PasswordVaultRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyVaultRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func recoveryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("profile.unreadable-") && $0.pathExtension == "vault" }
    }

    @Test(arguments: [CocoaError.Code.fileWriteNoPermission, .fileWriteFileExists])
    func failedPreservationBlocksSavingAndCanBeRetried(_ failure: CocoaError.Code) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.vault")
        let original = Data("unreadable synthetic vault".utf8)
        try original.write(to: file)
        let key = MemoryVaultKey(Data(repeating: 7, count: 32))
        let originalKey = key.key
        let vault = PasswordVault(fileURL: file, key: key, now: { now })
        try #require(await vault.load() == false)
        let move = vault.moveRecoveryFile
        var attempts = 0
        vault.moveRecoveryFile = { source, _ in
            #expect(source == file)
            attempts += 1
            throw CocoaError(failure)
        }

        vault.resetUnreadable()

        #expect(attempts == 1 && !vault.isReady)
        if case .unavailable(let message, let canReset) = vault.state {
            #expect(canReset && message.contains("weren’t reset"), "Settings explains the preservation failure and allows a retry")
        } else {
            Issue.record("A failed recovery move must leave Passwords unavailable")
        }
        #expect(vault.save(origin: "https://example.com", username: "blocked", password: "synthetic") == nil)
        _ = await vault.flush()
        #expect(try Data(contentsOf: file) == original)
        #expect(try recoveryFiles(in: directory).isEmpty)
        #expect(key.key == originalKey)

        // Once preservation succeeds, a new vault may be saved and reopened.
        vault.moveRecoveryFile = move
        vault.resetUnreadable()
        try #require(vault.isReady && vault.logins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let recovered = try #require(recoveryFiles(in: directory).first)
        #expect(try Data(contentsOf: recovered) == original)
        #expect(vault.save(origin: "https://example.com", username: "new", password: "synthetic") == .added)
        #expect(await vault.flush())
        let reopened = PasswordVault(fileURL: file, key: key)
        #expect(await reopened.load())
        #expect(reopened.logins.map(\.username) == ["new"])
        #expect(try Data(contentsOf: recovered) == original, "New saves must not change the recovery copy")
    }

    @Test func resetsInTheSameSecondPreserveEveryVaultAndAnOlderRecoveryFile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.vault")
        let older = Data("older recovery copy".utf8)
        let legacy = directory.appendingPathComponent("profile.unreadable-1700000000.vault")
        try older.write(to: legacy)
        let originals = [Data("first unreadable vault".utf8), Data("second unreadable vault".utf8)]
        for original in originals {
            try original.write(to: file)
            let vault = PasswordVault(fileURL: file, key: MemoryVaultKey(), now: { now })
            try #require(await vault.load() == false)
            vault.resetUnreadable()
            #expect(vault.isReady)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: legacy) == older)
        }
        let copies = try recoveryFiles(in: directory)
        #expect(copies.count == 3)
        #expect(try Set(copies.map { try Data(contentsOf: $0) }) == Set(originals + [older]))
    }

    @Test func aDeniedKeychainRequestCannotBeReset() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.vault")
        let original = Data("synthetic saved bytes".utf8)
        try original.write(to: file)
        let key = MemoryVaultKey()
        key.failure = errSecAuthFailed
        let vault = PasswordVault(fileURL: file, key: key)
        try #require(await vault.load() == false)
        let unavailable = vault.state
        vault.moveRecoveryFile = { _, _ in Issue.record("A denied Keychain request must not move the vault") }
        vault.resetUnreadable()
        #expect(vault.state == unavailable && !vault.isReady)
        #expect(try Data(contentsOf: file) == original)
        #expect(try recoveryFiles(in: directory).isEmpty)
    }

    @Test func aMissingSourceCannotBeResetWithoutPreservation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.vault")
        try Data("unreadable synthetic vault".utf8).write(to: file)
        let vault = PasswordVault(fileURL: file, key: MemoryVaultKey())
        try #require(await vault.load() == false)
        try FileManager.default.removeItem(at: file)

        vault.resetUnreadable()

        #expect(!vault.isReady)
        #expect(vault.save(origin: "https://example.com", username: "blocked", password: "synthetic") == nil)
        #expect(try recoveryFiles(in: directory).isEmpty)
        // Try Again reloads the current disk state rather than claiming a reset succeeded.
        #expect(await vault.load(retry: true))
        #expect(vault.logins.isEmpty)
    }
}
