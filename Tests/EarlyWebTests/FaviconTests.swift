// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import ImageIO
import Testing

private let iconPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

@Suite struct FaviconTests {
    @Test @MainActor func candidatesAreBoundedResolvedAndSafe() {
        let page = URL(string: "https://Example.com:443/path/page?q=secret#part")!
        #expect(FaviconStore.origin(page) == "https://example.com")
        #expect(FaviconStore.candidates(pageURL: page, discovered: [
            "../icon.png", "https://cdn.example.com/icon.ico", "../icon.png",
            "data:image/png;base64,abc", "file:///tmp/icon", "javascript:alert(1)",
            "http://example.com/insecure.ico", "https://user:secret@example.com/icon"
        ]).map(\.absoluteString) == [
            "https://Example.com:443/icon.png", "https://cdn.example.com/icon.ico", "https://example.com/favicon.ico"
        ])
        #expect(FaviconStore.origin(URL(string: "file:///tmp/page")!) == nil)
        #expect(FaviconStore.candidates(pageURL: page, discovered: (0..<50).map { "/\($0).png" }).count == 4)
    }

    @Test func decodingRejectsInvalidAndOversizedResponses() throws {
        let png = try #require(FaviconLoader.thumbnail(iconPNG))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 1000) <= 64)
        #expect(FaviconLoader.thumbnail(Data("<html>not an icon</html>".utf8)) == nil)
        #expect(FaviconLoader.thumbnail(Data(repeating: 0, count: FaviconLoader.byteLimit + 1)) == nil)
    }

    @Test func fallbackAndProfileDiskCacheWorkWithoutCookies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Early-Favicon-Test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconProtocol.self]
        let loader = FaviconLoader(directory: directory, configuration: configuration)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        let candidates = ["https://fixture.invalid/missing", "https://fixture.invalid/favicon.ico"].map { URL(string: $0)! }
        let data = try #require(await loader.load(origin: "https://fixture.invalid", candidates: candidates, preferCache: true))
        #expect(FaviconLoader.thumbnail(data) != nil)
        // New loader / process state can restore the cached icon without a request.
        let restored = FaviconLoader(directory: directory, configuration: configuration)
        #expect(await restored.load(origin: "https://fixture.invalid", candidates: [], preferCache: true) == data)
        let otherProfile = FaviconLoader(directory: directory.appendingPathComponent("other"), configuration: configuration)
        #expect(await otherProfile.load(origin: "https://fixture.invalid", candidates: [], preferCache: true) == nil)
        #expect(await loader.load(origin: "https://large.invalid", candidates: [URL(string: "https://fixture.invalid/oversized")!], preferCache: false) == nil)
    }

    @Test @MainActor func duplicateRequestsAndLateFallbackDoNotReplaceDiscovery() async throws {
        let probe = IconProbe()
        let store = FaviconStore { _, _, cached in await probe.load(cached: cached) }
        let url = URL(string: "https://fixture.invalid/page")!
        for _ in 0..<20 { store.request(url) }
        store.request(url, discovered: ["/brand.png"])
        for _ in 0..<200 {
            if store.image(for: url) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.image(for: url) != nil)
        #expect(await probe.calls == [true, false])
        store.request(url)
        store.request(url, discovered: ["/brand.png"])
        await Task.yield()
        #expect(await probe.calls == [true, false])
        // Artwork is shared between same-site tabs, without mixing origins.
        #expect(store.image(for: URL(string: "https://fixture.invalid/other")!) != nil)
        #expect(store.image(for: URL(string: "https://another.invalid")!) == nil)
    }

    @Test @MainActor func livePageDiscoversDeclaredIconWithoutAnotherWebView() async throws {
        _ = NSApplication.shared
        let probe = DiscoveryProbe()
        let icons = FaviconStore { _, candidates, _ in await probe.record(candidates); return iconPNG }
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, faviconStore: icons)
        defer { manager.discardAll() }
        let url = URL(string: "https://fixture.invalid/page")!
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Fixture", currentURL: url)
        manager.prepare(tab).view.loadHTMLString("""
            <html><head><base href="https://cdn.fixture.invalid/art/">
            <link rel="shortcut icon" href="brand.png"></head><body>Fixture</body></html>
            """, baseURL: url)
        for _ in 0..<200 {
            if icons.image(for: url) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(icons.image(for: url) != nil)
        #expect(await probe.candidates.first?.absoluteString == "https://cdn.fixture.invalid/art/brand.png")
        #expect(manager.creationCount == 1)
        manager.discardAll()
        #expect(icons.image(for: url) != nil) // Closed pins retain the site's cached artwork.
    }
}

private actor DiscoveryProbe {
    var candidates: [URL] = []
    func record(_ urls: [URL]) { candidates = urls }
}

private actor IconProbe {
    var calls: [Bool] = []
    func load(cached: Bool) async -> Data? {
        calls.append(cached)
        if cached { try? await Task.sleep(for: .milliseconds(20)); return nil }
        return iconPNG
    }
}

private final class IconProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data = url.path == "/oversized" ? Data(repeating: 0, count: FaviconLoader.byteLimit + 1) : iconPNG
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/missing" ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png", "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
