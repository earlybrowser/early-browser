// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import Testing

@Suite(.serialized) @MainActor
struct PasswordExportApplicationTests {
    @MainActor private final class Pause {
        var entered = false
        var isCurrent = true
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func unlocked() async throws -> PasswordsLock {
        let lock = PasswordsLock()
        lock.authenticate = { _ in true }
        try #require(await lock.unlock())
        return lock
    }

    private func vault() -> PasswordVault {
        let vault = PasswordVault(fileURL: nil, key: nil)
        vault.save(origin: "https://example.test", username: "synthetic", password: "before")
        return vault
    }

    @Test(arguments: ["authentication", "destination"])
    func changedProfilesLocksAndDeletedVaultsCannotExportFromAnOldPrompt(stage: String) async throws {
        for change in ["profile", "lock", "delete", "cancel"] {
            let lock = try await unlocked(), vault = vault(), export = PasswordExport(), pause = Pause()
            defer { lock.lock(); pause.release(); export.cancel() }
            if stage == "authentication" { lock.authenticate = { _ in await pause.wait(); return true } }
            export.start(from: vault, lock: lock, isCurrent: { pause.isCurrent }, chooseDestination: {
                if stage == "destination" { await pause.wait() }
                return URL(fileURLWithPath: "/unused-password-export.csv")
            }, write: { _, _ in Issue.record("A stale or cancelled prompt must never reach the writer") })
            try await wait { pause.entered }
            switch change {
            case "profile": pause.isCurrent = false
            case "lock": lock.lock()
            case "delete": try await vault.removeAll()
            default: export.cancel()
            }
            pause.release()
            try await wait { !export.isRunning }
            #expect(export.notice == nil)
        }
    }

    @Test func aCancelledDestinationOrDeniedAuthenticationDoesNotExport() async throws {
        let lock = try await unlocked(), vault = vault(), export = PasswordExport()
        defer { lock.lock() }
        for denied in [false, true] {
            lock.authenticate = { _ in !denied }
            export.start(from: vault, lock: lock, isCurrent: { true }, chooseDestination: {
                #expect(!denied)
                return nil
            }, write: { _, _ in Issue.record("Nothing was authorized for export") })
            try await wait { !export.isRunning }
            #expect(export.notice == nil)
        }
    }

    @Test func exportUsesItsSnapshotAndReportsSuccessAfterALateCancel() async throws {
        let lock = try await unlocked(), vault = vault(), export = PasswordExport(), pause = Pause()
        defer { lock.lock(); pause.release(); export.cancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyExportSnapshot-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        export.start(from: vault, lock: lock, isCurrent: { true }, chooseDestination: { file }, write: { snapshot, url in
            await pause.wait()
            try await PasswordCSV.export(snapshot, to: url)
            // The destination exists: caller cancellation cannot undo this.
            await MainActor.run { export.cancel() }
        })
        try await wait { pause.entered }
        #expect(export.phase == .writing)
        vault.save(origin: "https://example.test", username: "synthetic", password: "after")
        try await vault.removeAll()
        // A second request cannot replace the active export's state or result.
        export.start(from: self.vault(), lock: lock, isCurrent: { true }, chooseDestination: {
            Issue.record("An export is already in progress"); return nil
        })
        pause.release()
        try await wait { !export.isRunning }
        #expect(export.notice?.title == "Passwords exported")
        #expect(try PasswordCSV.parse(String(contentsOf: file, encoding: .utf8)).rows.first?.password == "before")
    }

    @Test(arguments: [false, true])
    func cancellationAndFailuresWaitForTheWriterAndAreReported(cancelling: Bool) async throws {
        let lock = try await unlocked(), vault = vault(), export = PasswordExport(), pause = Pause()
        defer { lock.lock(); pause.release(); export.cancel() }
        export.start(from: vault, lock: lock, isCurrent: { true }, chooseDestination: {
            URL(fileURLWithPath: "/unused-password-export.csv")
        }, write: { _, _ in
            await pause.wait()
            try Task.checkCancellation()
            throw CocoaError(.fileWriteOutOfSpace)
        })
        try await wait { pause.entered }
        if cancelling {
            export.cancel()
            #expect(export.phase == .cancelling && export.notice == nil)
        }
        pause.release()
        try await wait { !export.isRunning }
        #expect(export.notice?.title == (cancelling ? "Export cancelled" : "The passwords couldn’t be exported"))
    }
}
