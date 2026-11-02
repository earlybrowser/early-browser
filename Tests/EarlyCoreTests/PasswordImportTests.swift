// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite
struct PasswordImportParsingTests {
    @Test func boundsRejectWholeFilesRowsFieldsAndColumns() throws {
        let csv = "url,username,password\nhttps://example.com,ada,synthetic\n"
        var limits = PasswordCSV.Limits()
        limits.maximumBytes = csv.utf8.count
        #expect(try PasswordCSV.parse(csv, limits: limits).rows.count == 1)
        limits.maximumBytes -= 1
        #expect(throws: PasswordCSV.Failure.capacity) { try PasswordCSV.parse(csv, limits: limits) }
        limits = .standard; limits.maximumRows = 1
        #expect(throws: PasswordCSV.Failure.capacity) {
            try PasswordCSV.parse(csv + "https://other.example,grace,other\n", limits: limits)
        }
        limits = .standard; limits.maximumFieldBytes = 32
        let large = "url,password\nhttps://example.com,\"" + String(repeating: "é", count: 17) + "\"\n"
        #expect(throws: PasswordCSV.Failure.capacity) { try PasswordCSV.parse(large, limits: limits) }
        limits = .standard; limits.maximumColumns = 3
        #expect(throws: PasswordCSV.Failure.capacity) { try PasswordCSV.parse(csv + "a,b,c,d\n", limits: limits) }
        #expect(throws: PasswordCSV.Failure.malformed) { try PasswordCSV.parse("url,password\nhttps://example.com,\"unfinished") }
    }

    @Test func supportedEncodingsAndQuotedUnicodeRoundTripWithoutTruncation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCSVRead-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Export aliases cover Safari/Apple, Firefox, Chrome/Edge,
        // 1Password, Bitwarden and LastPass in PasswordCSVTests as well.
        let csv = "\u{FEFF}URL,Username,Password,Notes\r\nhttps://example.com,\"a,é\",\"p\"\"w\",\"line1\r\nline2\"\r\n"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            let file = directory.appendingPathComponent("\(encoding.rawValue).csv")
            try #require(csv.data(using: encoding)).write(to: file)
            let result = try PasswordCSV.read(file)
            #expect(result.rows == [.init(origin: "https://example.com", username: "a,é", password: "p\"w", note: "line1\r\nline2")])
        }
        let latin = directory.appendingPathComponent("latin.csv")
        try #require("url,password\nhttps://example.com,café\n".data(using: .isoLatin1)).write(to: latin)
        #expect(try PasswordCSV.read(latin).rows.first?.password == "café")
        let notes = String(repeating: "x", count: 100_000)
        let longNote = try PasswordCSV.parse("url,password,notes\nhttps://example.com,pw,\(notes)\n")
        #expect(longNote.rows.first?.note == notes)
        var limit = PasswordCSV.Limits(); limit.maximumBytes = 5
        #expect(throws: PasswordCSV.Failure.capacity) { try PasswordCSV.read(latin, limits: limit) }
        #expect(throws: PasswordCSV.Failure.capacity) { try PasswordCSV.read(directory) }
    }

    @Test func cancellationRejectsParsingAndReading() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PasswordCSV.parse("url,password\nhttps://example.com,pw\n")
        }
        do { _ = try await task.value; Issue.record("Cancelled parsing must not succeed") }
        catch { #expect(error is CancellationError) }
        let read = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PasswordCSV.read(URL(fileURLWithPath: "/does-not-exist"))
        }
        do { _ = try await read.value; Issue.record("Cancelled reading must not open a file") }
        catch { #expect(error is CancellationError) }
    }
}

@Suite @MainActor
struct PasswordImportLifecycleTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
        private var entered = false
        var started: Bool { lock.withLock { entered } }
        func wait() throws {
            #expect(!Thread.isMainThread)
            lock.withLock { entered = true }
            guard signal.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
        }
        func release() { signal.signal() }
    }
    private func wait(_ gate: Gate) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.started {
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func parsed() throws -> PasswordCSV.Parsed {
        try PasswordCSV.parse("url,username,password\nhttps://example.com,ada,imported\nhttps://other.example,grace,new\n")
    }

    @Test func backgroundReadingPreservesInterveningEditsAndDrafts() async throws {
        let vault = PasswordVault(fileURL: nil, key: nil), gate = Gate(), rows = try parsed()
        defer { gate.release() }
        let task = Task { try await vault.importCSV(read: { try gate.wait(); return rows }) }
        try await wait(gate)
        vault.save(origin: "https://example.com", username: "ada", password: "keep this edit")
        vault.saveDraft(origin: "https://draft.example", username: "draft", password: "generated")
        gate.release()
        let result = try await task.value
        #expect(result.added == 1 && result.conflicts == 1)
        #expect(vault.login(origin: "https://example.com", username: "ada")?.password == "keep this edit")
        #expect(vault.drafts.first?.password == "generated")
    }

    @Test func cancellationAndProfileDeletionBeforeCommitImportNothing() async throws {
        for deleting in [false, true] {
            let vault = PasswordVault(fileURL: nil, key: nil), gate = Gate(), rows = try parsed()
            defer { gate.release() }
            let task = Task { try await vault.importCSV(read: { try gate.wait(); return rows }) }
            try await wait(gate)
            if deleting { try await vault.removeAll() } else { task.cancel() }
            gate.release()
            do { _ = try await task.value; Issue.record("Cancelled or deleted destination must not import") }
            catch { #expect(error is CancellationError || (error as? PasswordVault.ImportFailure) == .unavailable) }
            #expect(vault.logins.isEmpty)
        }
    }

    @Test func saveFailureKeepsImportedPasswordsForRetryAndSuccessIsDurable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCSVSave-\(UUID())/profile.vault")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let key = MemoryVaultKey(), vault = PasswordVault(fileURL: file, key: key, now: { date }), rows = try parsed()
        #expect(await vault.load())
        let writer = vault.writeFile
        vault.writeFile = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        do { _ = try await vault.importCSV(read: { rows }); Issue.record("Failed writes must not report import success") }
        catch { #expect((error as? PasswordVault.ImportFailure) == .saving) }
        #expect(vault.logins.count == 2 && vault.saveError != nil)
        vault.writeFile = writer
        vault.retrySaving()
        #expect(await vault.flush())
        let reopened = PasswordVault(fileURL: file, key: key)
        #expect(await reopened.load() && reopened.logins == vault.logins)
    }

    @Test func cancellationAfterCommitWaitsForDurabilityAndReportsActualOutcome() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCSVCommit-\(UUID())/profile.vault")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = MemoryVaultKey(), vault = PasswordVault(fileURL: file, key: key), rows = try parsed(), gate = Gate()
        defer { gate.release() }
        #expect(await vault.load())
        let writer = vault.writeFile
        vault.writeFile = { data, url in try gate.wait(); try writer(data, url) }
        let task = Task { try await vault.importCSV(read: { rows }) }
        try await wait(gate)
        task.cancel()
        #expect(vault.logins.count == 2)
        gate.release()
        #expect(try await task.value.added == 2)
        let reopened = PasswordVault(fileURL: file, key: key)
        #expect(await reopened.load() && reopened.logins.count == 2)
    }
}
