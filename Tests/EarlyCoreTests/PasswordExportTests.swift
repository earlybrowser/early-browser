// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import Testing
@testable import EarlyCore

@Suite(.serialized) @MainActor
struct PasswordExportTests {
    private final class WriterGate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var staged: URL?
        var temporary: URL? { lock.withLock { staged } }

        func pause(_ file: FileHandle, _ data: Data) throws {
            // Fail promptly in a control run instead of blocking the main actor.
            try #require(!Thread.isMainThread, "Password serialization and writing must run off-main")
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            try #require(fcntl(file.fileDescriptor, F_GETPATH, &path) == 0)
            let url = path.withUnsafeBufferPointer {
                URL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: false, relativeTo: nil)
            }
            try file.write(contentsOf: data.prefix(data.count / 2))
            lock.withLock { staged = url }
            guard semaphore.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
            try file.write(contentsOf: data.suffix(from: data.count / 2))
        }
        func release() { semaphore.signal() }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyBackgroundPasswordExport-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let logins = [SavedLogin(origin: "https://example.test", username: "synthetic", password: "test,\"🌅\"\npassword")]

    @Test(arguments: [false, true])
    func delayedExportsAllowMainActorWorkAndCancelBeforeReplacement(cancelling: Bool) async throws {
        let directory = try directory(), gate = WriterGate()
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Passwords.csv")
        try Data("previous export".utf8).write(to: url)
        let snapshot = logins
        let task = Task { try await PasswordCSV.export(snapshot, to: url, writeContents: gate.pause) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while gate.temporary == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        // This runs on the main actor while the background writer is blocked.
        #expect(try String(contentsOf: url, encoding: .utf8) == "previous export")
        let staged = try #require(gate.temporary)
        #expect(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int == 0o600)
        if cancelling { task.cancel() }
        gate.release()
        if cancelling {
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try String(contentsOf: url, encoding: .utf8) == "previous export")
        } else {
            try await task.value
            #expect(try String(contentsOf: url, encoding: .utf8) == PasswordCSV.export(logins))
        }
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func cancellationBeforeStartingCreatesNoExport() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Passwords.csv"), snapshot = logins
        let task = Task { try await PasswordCSV.export(snapshot, to: url) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func cancellationAfterCommitStillReportsSuccess() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Passwords.csv"), snapshot = logins
        try await BackgroundFileIO.run {
            try PasswordCSV.write(PasswordCSV.export(snapshot), to: url)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == PasswordCSV.export(logins))
    }

    @Test func largeBackgroundExportsKeepCSVCompatibilityAndOwnerOnlyPermissions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Passwords.csv")
        let snapshot = (0..<5_000).map { index in
            SavedLogin(origin: "https://site\(index).test", username: "synthetic\(index)",
                       password: "synthetic,\"quoted\"\n日本語", note: " synthetic note ")
        }
        try await PasswordCSV.export(snapshot, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == PasswordCSV.export(snapshot))
        #expect(try PasswordCSV.parse(contents).rows.count == snapshot.count)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
