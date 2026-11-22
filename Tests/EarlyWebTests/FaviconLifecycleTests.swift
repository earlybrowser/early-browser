// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct FaviconLifecycleTests {
    @Test func failedIconsBackOffWithAnUpperBoundAndKeepTheirDeclaredCandidates() async throws {
        let clock = TestClock()
        let probe = RetryProbe(successOn: 6)
        let store = FaviconStore(appearance: .light, now: clock.read) { _, urls, _ in await probe.load(urls) }
        let url = URL(string: "https://fixture.invalid")!
        store.request(url, discovered: ["/brand.png"])
        try await waitForFavicon("first failure") { clock.reads == 1 }
        for (offset, delay) in [5, 15, 60, 300, 300].enumerated() {
            let completed = offset + 1
            clock.advance(.seconds(delay - 1))
            for _ in 0..<20 { store.request(url, discovered: ["/brand.png"]) }
            #expect(await probe.paths.count == completed)

            let reads = clock.reads
            clock.advance(.seconds(1))
            // A sidebar row supplies no discovered URLs, but retry uses the
            // existing declaration rather than starting from /favicon.ico.
            for _ in 0..<20 { store.request(url) }
            if completed < 5 {
                try await waitForFavicon("retry failed after its backoff") { clock.reads > reads + 1 }
            } else {
                try await waitForFavicon("successful retry") { store.image(for: url) != nil }
            }
            #expect(await probe.paths.count == completed + 1)
        }
        #expect(await probe.paths == Array(repeating: "/brand.png", count: 6))
        await store.shutdown()
    }

    @Test func reloadRetriesTheUnchangedIconAndKeepsTheWebView() async throws {
        _ = NSApplication.shared
        let server = try HTMLServer(pages: ["/page": "<title>Test</title><link rel='icon' href='/brand.png'>"])
        defer { server.stop() }
        let clock = TestClock(), probe = RetryProbe(successOn: 2)
        let store = FaviconStore(appearance: .light, now: clock.read) { _, urls, _ in await probe.load(urls) }
        let profile = UUID(), url = server.url("/page")
        let manager = WebViewManager(profileID: profile, ephemeral: true, faviconStore: store, observesMemoryPressure: false)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Test", currentURL: url)
        manager.load(url, in: tab)
        let page = try #require(manager.pages[tab.id])
        try await waitForFavicon("page and icon failure") { page.loadProgress.phase == .completed && clock.reads > 0 }
        #expect(await probe.paths == ["/brand.png"])
        let cycle = page.loadProgress.generation

        manager.reload(tab.id)
        try await waitForFavicon("reloaded page and successful icon") {
            page.loadProgress.phase == .completed && FaviconStore.Appearance.allCases.contains {
                store.image(for: url, appearance: $0) != nil
            }
        }
        #expect(page.loadProgress.generation != cycle && manager.creationCount == 1)
        #expect(manager.pages[tab.id] === page)
        #expect(await probe.paths == ["/brand.png", "/brand.png"])
        await store.shutdown()
    }

    @Test func cancelledLoadsKeepTheirSlotsAndCannotDetachTheReplacement() async throws {
        let gate = LoadGate()
        defer { Task { await gate.abandon() } }
        let store = FaviconStore(appearance: .light) { key, urls, _ in await gate.load(key, urls) }
        let old = (0..<4).map { URL(string: "https://old\($0).invalid")! }
        let new = (0..<3).map { URL(string: "https://new\($0).invalid")! }
        for (index, url) in old.enumerated() { store.request(url, discovered: ["/old-\(index)"]) }
        try await waitForFavicon("four loaders started") { await gate.holding.count == 4 }
        store.forget(keeping: [])
        try await waitForFavicon("asked all four loads to cancel") { await gate.cancelled.count == 4 }
        store.request(old[0], discovered: ["/replacement"])
        for (index, url) in new.enumerated() { store.request(url, discovered: ["/new-\(index)"]) }

        await gate.finish("old-1", "old-2", "old-3")
        try await waitForFavicon("three independent loads began") {
            await gate.holding.isSuperset(of: ["old-0", "new-0", "new-1", "new-2"])
        }
        #expect(await !gate.started.contains("replacement"))
        await gate.finish("old-0")
        try await waitForFavicon("same-key replacement began") { await gate.holding.contains("replacement") }
        #expect(await gate.peak == 4)
        #expect(store.image(for: old[0]) == nil)

        store.forget(keeping: new)
        try await waitForFavicon("replacement is still tracked") { await gate.cancelled.contains("replacement") }
        store.request(old[0], discovered: ["/final"])
        await gate.finish("replacement", "new-0", "new-1", "new-2")
        try await waitForFavicon("final same-key request") { await gate.holding.contains("final") }
        await gate.finish("final")
        try await waitForFavicon("replacement artwork installed") { store.image(for: old[0]) != nil }
        #expect(await gate.peak == 4)
        await store.shutdown()
    }

    @Test func profileClearDrainsBothWindowsAndProtectsFreshAndPrivateRequests() async throws {
        let profile = UUID(), directory = try #require(FaviconStore.cacheDirectory(for: profile))
        let gate = LoadGate()
        defer {
            Task { await gate.abandon() }
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = URL(string: "https://kept.invalid")!
        let old = URL(string: "https://old.invalid")!, second = URL(string: "https://second.invalid")!
        let keptFiles = [file(for: kept, in: directory), file(for: kept, .light, in: directory), file(for: kept, .dark, in: directory)]
        let earlier = file(for: URL(string: "https://earlier.invalid")!, .light, in: directory)
        let oldFile = file(for: old, .light, in: directory), secondFile = file(for: second, .dark, in: directory)
        for file in keptFiles + [earlier, oldFile, secondFile] { try iconPNG.write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: earlier.path)
        let firstStore = FaviconStore(appearance: .light, profileID: profile) { key, urls, _ in
            if urls.first?.host == kept.host { return iconPNG }
            return await gate.load(key, urls, directory: directory)
        }
        let secondStore = FaviconStore(appearance: .dark, profileID: profile) { key, urls, _ in
            await gate.load(key, urls, directory: directory)
        }
        let privateStore = FaviconStore(appearance: .light, profileID: profile, ephemeral: true) { key, urls, _ in
            await gate.load(key, urls)
        }
        let firstWindow = WebViewManager(profileID: profile, faviconStore: firstStore,
                                         websiteDataStore: .nonPersistent(), observesMemoryPressure: false)
        let secondWindow = WebViewManager(profileID: profile, faviconStore: secondStore,
                                          websiteDataStore: firstWindow.websiteDataStore, observesMemoryPressure: false)
        firstWindow.favicons.request(kept)
        firstWindow.favicons.request(kept, appearance: .dark)
        firstWindow.favicons.request(old, discovered: ["/first-old"])
        secondWindow.favicons.request(second, discovered: ["/second-old"])
        privateStore.request(old, discovered: ["/private"])
        try await waitForFavicon("both windows and the private load") { await gate.holding.count == 3 }
        try await waitForFavicon("sidebar artwork") {
            firstStore.image(for: kept, appearance: .light) != nil && firstStore.image(for: kept, appearance: .dark) != nil
        }
        var cleared = false
        let clear = Task {
            await firstWindow.clearWebsiteData(since: Date(timeIntervalSince1970: 20), keepingIconsFor: [kept])
            cleared = true
        }
        try await waitForFavicon("both old loads cancelled") {
            await gate.cancelled.isSuperset(of: ["first-old", "second-old"])
        }
        secondWindow.favicons.request(second, discovered: ["/replacement"])
        let newWindow = FaviconStore(appearance: .light, profileID: profile) { key, urls, _ in
            await gate.load(key, urls, directory: directory)
        }
        newWindow.request(old, discovered: ["/new-window"])
        await gate.finish("first-old")
        try await waitForFavicon("first delayed write") { await gate.wrote.contains("first-old") }
        #expect(!cleared)
        #expect(await gate.holding == ["second-old", "private"])
        await gate.finish("second-old")
        try await waitForFavicon("profile clear finished") { cleared }
        await clear.value

        #expect(await gate.wrote == ["first-old", "second-old"])
        #expect(!FileManager.default.fileExists(atPath: oldFile.path) && !FileManager.default.fileExists(atPath: secondFile.path))
        #expect((keptFiles + [earlier]).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(firstStore.image(for: kept, appearance: .light) != nil && firstStore.image(for: kept, appearance: .dark) != nil)
        #expect(await !gate.cancelled.contains("private"))
        try await waitForFavicon("fresh requests began after clearing") {
            await gate.holding.isSuperset(of: ["replacement", "new-window"])
        }
        await gate.finish("replacement", "new-window", "private")
        try await waitForFavicon("fresh artwork delivered to each store") {
            secondStore.image(for: second) != nil && newWindow.image(for: old) != nil && privateStore.image(for: old) != nil
        }
        await firstStore.shutdown()
        await secondStore.shutdown()
        await newWindow.shutdown()
        await privateStore.shutdown()
    }

    @Test func removingAProfileWaitsForAClosedWindowsWriter() async throws {
        let profile = UUID(), directory = try #require(FaviconStore.cacheDirectory(for: profile))
        let gate = LoadGate()
        defer {
            Task { await gate.abandon() }
            try? FileManager.default.removeItem(at: directory)
        }
        let otherProfile = UUID(), otherDirectory = try #require(FaviconStore.cacheDirectory(for: otherProfile))
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let url = URL(string: "https://fixture.invalid")!
        let untouched = file(for: url, .light, in: otherDirectory)
        try iconPNG.write(to: untouched)
        var store: FaviconStore? = FaviconStore(appearance: .light, profileID: profile) { key, urls, _ in
            await gate.load(key, urls, directory: directory)
        }
        weak var releasedStore = store
        store?.request(url, discovered: ["/closed"])
        try await waitForFavicon("closed window's request starting") { await gate.holding.contains("closed") }
        store = nil
        #expect(releasedStore == nil)
        let deletion = Task { try await FaviconStore.removeCache(for: profile) }
        try await waitForFavicon("closed window's request cancelled") { await gate.cancelled.contains("closed") }
        await gate.finish("closed")
        try await deletion.value
        #expect(await gate.wrote.contains("closed"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: untouched.path))
    }

    private func file(for url: URL, _ appearance: FaviconStore.Appearance? = nil, in directory: URL) -> URL {
        let origin = FaviconStore.origin(url)!
        let identifier = appearance.map { origin + "#favicon-" + $0.rawValue } ?? origin
        return directory.appendingPathComponent(FaviconLoader.fileName(for: identifier))
    }
}

@MainActor private final class TestClock {
    private var instant = ContinuousClock.now
    private(set) var reads = 0
    func read() -> ContinuousClock.Instant { reads += 1; return instant }
    func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

private actor RetryProbe {
    let successOn: Int
    var paths: [String] = []
    init(successOn: Int) { self.successOn = successOn }
    func load(_ urls: [URL]) -> Data? {
        paths.append(urls.first?.path ?? "")
        return paths.count >= successOn ? iconPNG : nil
    }
}

/// Represents a loader already past its last cancellation check. The gate
/// keeps its physical work alive and can still produce a real disk write.
private actor LoadGate {
    private var waits: [String: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    private var abandoned = false
    private(set) var peak = 0
    private(set) var started = Set<String>()
    private(set) var cancelled = Set<String>()
    private(set) var wrote = Set<String>()
    var holding: Set<String> { Set(waits.keys) }

    func load(_ key: String, _ urls: [URL], directory: URL? = nil) async -> Data? {
        guard !abandoned, let name = urls.first?.lastPathComponent else { return nil }
        active += 1
        peak = max(peak, active)
        started.insert(name)
        defer { active -= 1 }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waits[name] = $0 }
        } onCancel: {
            Task { await self.recordCancellation(name) }
        }
        guard !abandoned else { return nil }
        if let directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try iconPNG.write(to: directory.appendingPathComponent(FaviconLoader.fileName(for: key)), options: .atomic)
                wrote.insert(name)
            } catch { Issue.record("Fixture artwork write failed: \(error)") }
        }
        return iconPNG
    }

    private func recordCancellation(_ name: String) { cancelled.insert(name) }
    func finish(_ names: String...) { for name in names { waits.removeValue(forKey: name)?.resume() } }

    func abandon() {
        abandoned = true
        for continuation in waits.values { continuation.resume() }
        waits.removeAll()
    }
}
