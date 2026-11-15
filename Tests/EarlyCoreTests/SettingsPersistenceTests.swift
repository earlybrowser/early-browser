// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct SettingsPersistenceTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func enter() throws {
            #expect(!Thread.isMainThread, "Reading, encoding and writing must leave the UI thread")
            let first = lock.withLock { count += 1; return count == 1 }
            if first, semaphore.wait(timeout: .now() + 10) != .success { throw CocoaError(.fileWriteUnknown) }
        }
        func release() { semaphore.signal() }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func permissionsLoadOffMainAndDenyRequestsUntilSavedChoicesAreKnown() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionsLoad-\(UUID()).json")
        let bytes = Data(#"{"https://example.com":{"camera":"allow","downloads":"block"}}"#.utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = Gate(), store = SitePermissions(fileURL: file)
        defer { gate.release() }
        store.persistence.readFile = { url in try gate.enter(); return try Data(contentsOf: url) }
        let load = Task { await store.load() }
        try await wait { gate.calls == 1 }
        #expect(store.isLoading && !store.isReady)
        #expect(store.decision(for: "https://example.com", .camera) == .block)
        store.set(.allow, for: [.downloads], origin: "https://example.com")
        #expect(store.decisions.isEmpty, "The incomplete catalog cannot overwrite saved choices")
        gate.release()
        #expect(await load.value)
        #expect(store.decision(for: "https://example.com", .camera) == .allow)
        #expect(store.decision(for: "https://example.com", .downloads) == .block)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func permissionBurstsCoalesceAndFlushIncludesTheNewestRevocation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionsSave-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = Gate(), store = SitePermissions(fileURL: file)
        defer { gate.release() }
        #expect(await store.load())
        store.persistence.writeFile = { bytes, url in try gate.enter(); try bytes.write(to: url, options: .atomic) }
        store.set(.allow, for: [.camera], origin: "https://example.com")
        try await wait { gate.calls == 1 }
        var flushed = false
        let flush = Task { flushed = await store.flush(); return flushed }
        for index in 0..<50 {
            store.set(index.isMultiple(of: 2) ? .allow : .block, for: [.camera], origin: "https://example.com")
        }
        #expect(store.decision(for: "https://example.com", .camera) == .block, "Revocation applies during the old disk write")
        #expect(store.isSaving && !flushed && gate.calls == 1)
        #expect(!(await store.flush(timeout: .milliseconds(20))), "Quit can offer Cancel while the disk is stalled")
        gate.release()
        #expect(await flush.value)
        #expect(gate.calls == 2, "Only the first and newest snapshots are written")
        let reopened = SitePermissions(fileURL: file)
        #expect(await reopened.load())
        #expect(reopened.decision(for: "https://example.com", .camera) == .block)
    }

    @Test func extensionRemovalDrainsTheWriterAndLateEditsCannotRecreateItsFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionsSave-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let catalog = ExtensionCatalog(fileURL: file), gate = Gate()
        defer { gate.release() }
        #expect(await catalog.load())
        catalog.persistence.writeFile = { bytes, url in try gate.enter(); try bytes.write(to: url, options: .atomic) }
        let item = InstalledExtension(source: .files(folderName: "fixture"), name: "Fixture", version: "1")
        catalog.add(item)
        try await wait { gate.calls == 1 }
        catalog.change(item.id) { $0.isEnabled = false }
        var removed = false
        let removal = Task { try await catalog.removeFile(); removed = true }
        try await wait { catalog.isRemoved }
        catalog.add(item)
        catalog.retrySaving()
        #expect(!removed && catalog.extensions.isEmpty)
        gate.release()
        try await removal.value
        #expect(await catalog.flush())
        #expect(gate.calls == 1 && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aReadFinishingAfterRemovalCannotRestoreGrants() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionsRemove-\(UUID()).json")
        try Data(#"{"https://example.com":{"camera":"allow"}}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = Gate(), store = SitePermissions(fileURL: file)
        defer { gate.release() }
        store.persistence.readFile = { url in
            let bytes = try Data(contentsOf: url)
            try gate.enter()
            return bytes
        }
        let load = Task { await store.load() }
        try await wait { gate.calls == 1 }
        let removal = Task { try await store.removeFile() }
        try await wait { !store.acceptsChanges }
        gate.release()
        try await removal.value
        #expect(!(await load.value))
        #expect(store.decisions.isEmpty && !store.isReady && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aBrokenExtensionCatalogIsPreservedUntilAReadRetrySucceeds() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionsRetry-\(UUID()).json")
        try Data("broken".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let catalog = ExtensionCatalog(fileURL: file)
        #expect(!(await catalog.load()) && catalog.loadError != nil)
        let item = InstalledExtension(source: .files(folderName: "fixture"), name: "Fixture", version: "1")
        catalog.add(item)
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
        try JSONEncoder().encode([item]).write(to: file)
        catalog.retrySaving()
        #expect(await catalog.flush())
        #expect(catalog.extensions == [item] && catalog.loadError == nil)
    }

    private struct CheckedValue: Codable, Sendable {
        let number: Int
        init(_ number: Int) { self.number = number }
        init(from decoder: any Decoder) throws {
            #expect(!Thread.isMainThread, "Decoding must leave the UI thread")
            number = try decoder.singleValueContainer().decode(Int.self)
        }
        func encode(to encoder: any Encoder) throws {
            #expect(!Thread.isMainThread, "Encoding must leave the UI thread")
            var container = encoder.singleValueContainer()
            try container.encode(number)
        }
    }

    @Test func encodingAndDecodingRunOnBackgroundWorkers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsCoding-\(UUID()).json")
        try Data("7".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let storage = SettingsPersistence(fileURL: file, empty: CheckedValue(0), decode: {
            try JSONDecoder().decode(CheckedValue.self, from: $0)
        }, encode: { try JSONEncoder().encode($0) })
        #expect(await storage.load())
        #expect(storage.value.number == 7)
        storage.change(CheckedValue(8))
        #expect(await storage.flush())
        #expect(try String(contentsOf: file, encoding: .utf8) == "8")
    }
}
