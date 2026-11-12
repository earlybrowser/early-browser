// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct PasswordVaultCleanupTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyVaultCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(arguments: [false, true])
    func deletionRemovesOnlyOwnedRecoveryFiles(opened: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.vault")
        let shared = directory.appendingPathComponent("Key")
        let key = FileVaultKey(file: shared, profile: UUID())
        let survivorKey = FileVaultKey(file: shared, profile: UUID())
        let survivorFile = directory.appendingPathComponent("profile-other.vault")
        let survivor = PasswordVault(fileURL: survivorFile, key: survivorKey)
        #expect(await survivor.load())
        survivor.save(origin: "https://example.com", username: "keep", password: "synthetic")
        #expect(await survivor.flush())
        let sharedBytes = try Data(contentsOf: shared)
        try Data("synthetic unreadable vault".utf8).write(to: file)
        let owned = ["profile.unreadable-1700000000.vault",
                     "profile.unreadable-1700000001-\(UUID().uuidString).vault"]
        let preserved = ["profile-other.unreadable-1700000000.vault", "profile.unreadable-not-a-timestamp.vault",
                         "profile.unreadable-1700000000-not-a-uuid.vault", "profile.unreadable-1700000000.vault.notes"]
        for name in owned + preserved { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }

        if opened {
            let vault = PasswordVault(fileURL: file, key: key)
            #expect(await vault.load() == false)
            try await vault.removeAll()
            #expect(!vault.isReady && vault.saveError == nil)
        } else {
            try await PasswordVault.remove(fileURL: file, key: key)
        }

        for name in owned + [file.lastPathComponent] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name) must be erased")
        }
        for name in preserved { #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == Data(name.utf8)) }
        #expect(try Data(contentsOf: shared) == sharedBytes)
        let reopened = PasswordVault(fileURL: survivorFile, key: survivorKey)
        #expect(await reopened.load())
        #expect(reopened.logins.map(\.username) == ["keep"])
    }

    @Test func failedRecoveryRemovalIsRetryableWhenTheMainVaultIsAlreadyGone() async throws {
        let directory = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("profile.vault")
        let recovery = directory.appendingPathComponent("profile.unreadable-1700000000.vault")
        let bytes = Data("synthetic recovery".utf8)
        try bytes.write(to: recovery)
        let key = MemoryVaultKey(Data(repeating: 7, count: 32), legacy: Data(repeating: 8, count: 32))
        let vault = PasswordVault(fileURL: file, key: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        await #expect(throws: (any Error).self) { try await vault.removeAll() }
        #expect(!vault.isReady && vault.saveError != nil)
        #expect(await vault.flush() == false)
        #expect(try Data(contentsOf: recovery) == bytes)
        #expect(key.key != nil && key.legacyKey != nil, "Keep keys until all owned files are erased")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Restart recovery has no live vault and may find the main file already absent.
        try await PasswordVault.remove(fileURL: file, key: key)
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        #expect(key.key == nil && key.legacyKey == nil)
        try await vault.removeAll()
        #expect(vault.saveError == nil)
        #expect(await vault.flush())
    }

    @Test func aMissingPasswordsDirectoryStillAllowsKeyCleanup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MemoryVaultKey(Data(repeating: 7, count: 32))
        try await PasswordVault.remove(fileURL: directory.appendingPathComponent("missing/profile.vault"), key: key)
        #expect(key.key == nil)
    }
}
