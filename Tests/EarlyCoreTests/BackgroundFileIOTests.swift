// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import Testing
@testable import EarlyCore

@Suite
struct BackgroundFileIOTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var entered = false
        private var stagedPath: String?
        var started: Bool { lock.withLock { entered } }
        var path: String? { lock.withLock { stagedPath } }
        func pause(_ file: FileHandle) throws {
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            let status = fcntl(file.fileDescriptor, F_GETPATH, &path)
            lock.withLock { entered = true; stagedPath = status == 0 ? String(cString: path) : nil }
            #expect(!Thread.isMainThread)
            guard semaphore.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
        func release() { semaphore.signal() }
    }

    private func wait(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.started {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func partialFailureAndCancellationKeepThePreviousFileAndRemoveStaging() async throws {
        for cancelling in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyAtomicIO-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("Saved.pdf"), gate = Gate()
            try Data("previous complete file".utf8).write(to: destination)
            defer { gate.release() }
            let task = Task {
                try await BackgroundFileIO.run {
                    try BackgroundFileIO.atomicDestination(destination) { output in
                        try output.write(contentsOf: Data("partial".utf8))
                        try gate.pause(output)
                        try Task.checkCancellation()
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                }
            }
            try await wait(gate)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous complete file")
            if cancelling { task.cancel() }
            gate.release()
            do { try await task.value; Issue.record("An incomplete replacement must fail") }
            catch { #expect(cancelling ? error is CancellationError : error is CocoaError) }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous complete file")
            let staged = try #require(gate.path)
            #expect(!FileManager.default.fileExists(atPath: staged))
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: staged).deletingLastPathComponent().path))
        }
    }

    @Test func successfulCopyIsCompleteAndSavingOntoTheSameFileIsHarmless() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCopyIO-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.pdf"), destination = directory.appendingPathComponent("Target.pdf")
        let bytes = Data(repeating: 0x5A, count: 2 * 1024 * 1024)
        try bytes.write(to: source)
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try await BackgroundFileIO.copy(source, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await BackgroundFileIO.copy(source, to: source)
        #expect(try Data(contentsOf: source) == bytes)
        let fifo = directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: CocoaError.self) { try await BackgroundFileIO.copy(fifo, to: destination) }
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func aCommittedSaveReportsSuccessEvenIfTheCallerCancelsAfterRename() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCommittedIO-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: file) }
        try await BackgroundFileIO.run {
            #expect(!Thread.isMainThread)
            try BackgroundFileIO.writeSynchronously(Data("complete".utf8), to: file)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "complete")
    }

    @Test func extensionCopiesNeverRemoveAnExistingFileOrDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyExtensionCopy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("extension".utf8).write(to: source.appendingPathComponent("manifest.json"))
        for folder in [false, true] {
            let target = directory.appendingPathComponent(folder ? "Existing Folder" : "Existing File")
            let sentinel: URL
            if folder {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                sentinel = target.appendingPathComponent("keep")
            } else { sentinel = target }
            try Data("keep".utf8).write(to: sentinel)
            await #expect(throws: POSIXError.self) {
                try await BackgroundFileIO.run { try ExtensionFileTransfer.copy(source, to: target) }
            }
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        }
        let copied = directory.appendingPathComponent("New Extension")
        try await BackgroundFileIO.run { try ExtensionFileTransfer.copy(source, to: copied) }
        #expect(try String(contentsOf: copied.appendingPathComponent("manifest.json"), encoding: .utf8) == "extension")
    }

    @Test func rapidArchiveBackupsRetainExactlyTheLatestFive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyRapidBackups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await BackgroundFileIO.run {
            var files: [URL] = []
            for _ in 0..<8 {
                files.append(try EarlyStateArchive.backup(workspace: BrowserWorkspace(), settings: nil,
                                                         in: directory, retaining: 5))
            }
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(Set(remaining.map(\.lastPathComponent)) == Set(files.suffix(5).map(\.lastPathComponent)))
        }
    }
}
