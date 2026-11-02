// SPDX-License-Identifier: MPL-2.0

import EarlyCore
@testable import EarlyWeb
import Foundation
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct BackgroundDocumentTests {
    private actor Gate {
        private var pending: [CheckedContinuation<Void, Never>] = []
        private(set) var started = 0
        func wait() async {
            started += 1
            await withCheckedContinuation { pending.append($0) }
        }
        func releaseAll() { let current = pending; pending = []; current.forEach { $0.resume() } }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func slowDocumentSavesYieldAndCancellingOnePageDoesNotCancelAnother() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyDocumentWorker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WebViewManager(profileID: UUID(), ephemeral: true, websiteDataStore: .nonPersistent(), observesMemoryPressure: false)
        defer { manager.discardAll() }
        let gate = Gate(), first = directory.appendingPathComponent("first.pdf"), second = directory.appendingPathComponent("second.pdf")
        try Data("old first".utf8).write(to: first)
        try Data("old second".utf8).write(to: second)
        var notices: [String] = []
        manager.onNotice = { notices.append($0) }
        manager.documentWriter = { data, file in
            await gate.wait()
            try Task.checkCancellation()
            try await BackgroundFileIO.write(data, to: file)
        }
        let one = UUID(), two = UUID()
        manager.write(.success(Data("new first".utf8)), to: first, source: nil, failure: "failure", pageID: one)
        manager.write(.success(Data("new second".utf8)), to: second, source: nil, failure: "failure", pageID: two)
        try await waitUntil { await gate.started == 2 }
        #expect(manager.documentWrites.count == 2 && manager.downloads.items.isEmpty)
        #expect(try String(contentsOf: first, encoding: .utf8) == "old first")
        manager.cancelDocumentPanel(one)
        await gate.releaseAll()
        try await waitUntil { manager.documentWrites.isEmpty }
        #expect(try String(contentsOf: first, encoding: .utf8) == "old first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "new second")
        #expect(manager.downloads.items.map(\.destination) == [second])
        #expect(notices.isEmpty)
    }

    @Test func aFailedDocumentSaveReportsFailureWithoutACompletedDownload() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyFailedDocument-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("kept".utf8).write(to: file)
        let manager = WebViewManager(profileID: UUID(), ephemeral: true, websiteDataStore: .nonPersistent(), observesMemoryPressure: false)
        defer { manager.discardAll() }
        var notice: String?
        manager.onNotice = { notice = $0 }
        manager.documentWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        manager.write(.success(Data("replacement".utf8)), to: file, source: nil, failure: "Could not save")
        try await waitUntil { manager.documentWrites.isEmpty }
        #expect(notice == "Could not save" && manager.downloads.items.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
    }
}

@Suite(.serialized) @MainActor
struct BackgroundExtensionTests {
    private final class CopyGate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var entered = false
        var started: Bool { lock.withLock { entered } }
        func wait() throws {
            #expect(!Thread.isMainThread)
            lock.withLock { entered = true }
            guard semaphore.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
        }
        func release() { semaphore.signal() }
    }

    @Test func profileRemovalDrainsPendingExtensionCopiesBeforeFilesAreErased() async throws {
        guard #available(macOS 15.4, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyExtensionWorker-\(UUID())")
        let source = directory.appendingPathComponent("Source"), files = directory.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        let catalog = ExtensionCatalog(fileURL: directory.appendingPathComponent("extensions.json"))
        let host = ExtensionHost(catalog: catalog, filesDirectory: files, websiteDataStore: .nonPersistent(), storageIdentifier: nil, isPrivate: false)
        let gate = CopyGate()
        defer { gate.release() }
        host.copyExtensionFiles = { source, destination in try gate.wait(); try ExtensionFileTransfer.copy(source, to: destination) }
        let install = Task { try await host.add(files: source) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.started {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        try catalog.removeFile()
        var removing = false, removed = false
        let removal = Task {
            removing = true
            try await host.removeAllData()
            try await BackgroundFileIO.run { try ProfileDataCleanup.removeItem(at: files) }
            removed = true
        }
        while !removing { await Task.yield() }
        #expect(!removed, "Deletion must wait for the old copy instead of allowing it to recreate the folder")
        gate.release()
        await #expect(throws: CancellationError.self) { try await install.value }
        try await removal.value
        #expect(removed && catalog.extensions.isEmpty && host.contexts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.path))
        #expect(try String(contentsOf: source.appendingPathComponent("manifest.json"), encoding: .utf8).contains("Synthetic"))
        await #expect(throws: CancellationError.self) { try await host.add(files: source) }
    }
}
