// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyWeb
import Testing

@Suite(.serialized) @MainActor
struct FaviconAppearanceTests {
    private let url = URL(string: "https://fixture.invalid/page")!
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

    @Test func appearancesHaveSeparateArtworkAndRestoringOneDoesNotRefetch() async throws {
        let probe = FaviconRequestProbe()
        let png = png
        let store = FaviconStore(appearance: .light) { key, urls, cached in
            await probe.record(key, urls, cached)
            return png
        }
        store.request(url, discovered: ["/light.png"])
        try await waitForFavicon { store.image(for: url) != nil }
        let light = try #require(store.image(for: url))

        store.setAppearance(.dark)
        #expect(store.image(for: url) == nil, "The previous appearance must not leak into the new one")
        store.request(url, discovered: ["/dark.png"])
        try await waitForFavicon { store.image(for: url) != nil }
        let dark = try #require(store.image(for: url))
        #expect(dark !== light)
        #expect(store.image(for: url, appearance: .light) === light)
        let count = await probe.calls.count
        store.setAppearance(.light)
        #expect(store.image(for: url) === light)
        await Task.yield()
        #expect(await probe.calls.count == count)
        let keys = await probe.calls.map(\.key)
        #expect(Set(keys).count == 2, "Disk loads must also distinguish appearance")

        store.forget(keeping: [url])
        #expect(store.image(for: url, appearance: .dark) === dark)
        store.forget(keeping: [])
        #expect(store.image(for: url, appearance: .dark) == nil)
        #expect(store.image(for: url, appearance: .light) == nil)
        await store.shutdown()
    }

    @Test func appearanceVariantsSurviveRelaunchAndWebsiteDataCleanup() async throws {
        let profile = UUID()
        let directory = try #require(FaviconStore.cacheDirectory(for: profile))
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = FaviconRequestProbe()
        let png = png
        let store = FaviconStore(appearance: .light) { key, urls, cached in
            await probe.record(key, urls, cached)
            return png
        }
        store.request(url, discovered: ["/light.png"])
        store.request(url, discovered: ["/dark.png"], appearance: .dark)
        try await waitForFavicon { store.image(for: url, appearance: .light) != nil && store.image(for: url, appearance: .dark) != nil }
        let calls = await probe.calls
        #expect(calls.count == 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for call in calls { try png.write(to: directory.appendingPathComponent(FaviconLoader.fileName(for: call.key))) }
        let loader = FaviconLoader(directory: directory)
        let restored = FaviconStore(appearance: .light) { key, urls, cached in
            // No network access: both variants must be restored from their own files.
            await loader.load(cacheKey: key, candidates: [], preferCache: cached)
        }
        restored.request(url)
        try await waitForFavicon { restored.image(for: url) != nil }
        restored.setAppearance(.dark)
        #expect(restored.image(for: url) == nil)
        try await waitForFavicon { restored.image(for: url) != nil }
        await FaviconStore.removeCachedIcons(for: profile, since: nil, keeping: [url])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
        await FaviconStore.removeCachedIcons(for: profile, since: nil, keeping: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await store.shutdown()
        await restored.shutdown()
    }

    @Test func removingDeclaredIconsReturnsToTheFallback() async throws {
        let probe = FaviconRequestProbe()
        let png = png
        let store = FaviconStore(appearance: .dark) { key, urls, cached in
            await probe.record(key, urls, cached)
            return png
        }
        store.request(url, discovered: ["/dark.png"])
        try await waitForFavicon { store.image(for: url) != nil }
        store.request(url, discovered: [])
        try await waitForFavicon { await probe.calls.last?.urls.first?.path == "/favicon.ico" }
        #expect(await probe.calls.last?.cached == false)
        await store.shutdown()
    }

    @Test func aLateLightIconCannotReplaceTheDisplayedDarkIcon() async throws {
        let gate = FaviconLoadGate()
        let png = png
        let store = FaviconStore(appearance: .light) { _, urls, _ in
            if urls.first?.path == "/light.png" { await gate.wait() }
            return png
        }
        store.request(url, discovered: ["/light.png"])
        try await waitForFavicon { await gate.isWaiting }
        store.setAppearance(.dark)
        store.request(url, discovered: ["/dark.png"])
        try await waitForFavicon { store.image(for: url) != nil }
        let dark = try #require(store.image(for: url))
        await gate.release()
        try await waitForFavicon { store.image(for: url, appearance: .light) != nil }
        #expect(store.image(for: url) === dark)
        await store.shutdown()
    }

    @Test func applicationAppearanceChangesRefreshClosedPinArtwork() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .aqua)
        let png = png
        let store = FaviconStore { _, _, _ in png }
        #expect(store.appearance == .light)
        store.request(url)
        try await waitForFavicon { store.image(for: url) != nil }
        let light = try #require(store.image(for: url))
        app.appearance = NSAppearance(named: .darkAqua)
        try await waitForFavicon { store.appearance == .dark && store.image(for: url) != nil }
        #expect(store.image(for: url) !== light)
        #expect(store.image(for: url, appearance: .light) === light)
        await store.shutdown()
    }
}

private actor FaviconRequestProbe {
    struct Call: Sendable { let key: String; let urls: [URL]; let cached: Bool }
    var calls: [Call] = []
    func record(_ key: String, _ urls: [URL], _ cached: Bool) { calls.append(Call(key: key, urls: urls, cached: cached)) }
}

private actor FaviconLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
func waitForFavicon(_ label: String = "favicon", _ condition: () async -> Bool) async throws {
    struct Timeout: Error, CustomStringConvertible { let description: String }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(label)") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
