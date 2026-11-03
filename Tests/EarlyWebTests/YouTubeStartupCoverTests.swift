// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct YouTubeStartupCoverTests {
    private static let youtube = URL(string: "https://www.youtube.com/")!

    @Test func whiteStartupStaysCoveredUntilYouTubePaintsItsDarkBackground() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.view.prepareInitialPage(for: Self.youtube)
        let cover = try #require(fixture.cover)
        fixture.load()
        try await fixture.waitForWhiteDocument()
        #expect(cover.superview === fixture.view)
        #expect(fixture.view.isLoading)
        #expect(try await fixture.view.evaluateJavaScript("document.documentElement.hasAttribute('dark')") as? Bool == false)

        fixture.view.frame.size = NSSize(width: 900, height: 650)
        fixture.view.layoutSubtreeIfNeeded()
        #expect(cover.frame == fixture.view.bounds)
        #expect(cover.hitTest(.zero) == nil && !cover.isAccessibilityElement())

        // The site's own theme update, before the rest of the page finishes.
        _ = try await fixture.view.evaluateJavaScript("document.documentElement.setAttribute('dark', '')")
        try await Self.waitUntil { cover.superview == nil }
        #expect(fixture.view.isLoading)
        #expect(try await fixture.view.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String == "rgb(15, 15, 15)")
        fixture.resource.finishTransfers()
        try await Self.waitUntil { !fixture.view.isLoading }

        // A later reload/navigation must retain the already visible page.
        fixture.view.prepareInitialPage(for: Self.youtube)
        #expect(fixture.cover == nil)
    }

    @Test func explicitlyLightYouTubeIsRevealedWithoutChangingItsStyles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.view.prepareInitialPage(for: Self.youtube)
        let cover = try #require(fixture.cover)
        fixture.load()
        try await fixture.waitForWhiteDocument()
        fixture.resource.finishTransfers()
        try await Self.waitUntil { !fixture.view.isLoading && cover.superview == nil }
        #expect(try await fixture.view.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String == "rgb(255, 255, 255)")
        #expect(try await fixture.view.evaluateJavaScript("document.documentElement.hasAttribute('dark')") as? Bool == false)
        #expect(try await fixture.view.evaluateJavaScript("document.documentElement.getAttribute('style')") is NSNull)
    }

    @Test func otherSitesLightAppearanceAndAlreadyLoadedPagesHaveNoCover() async throws {
        for address in ["https://example.com/", "https://youtube.com.example.com/", "https://studio.youtube.com/",
                        "https://www.youtube-nocookie.com/embed/test", "http://www.youtube.com/", "file:///youtube.com"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            fixture.view.prepareInitialPage(for: URL(string: address)!)
            #expect(fixture.cover == nil)
        }
        let light = try Fixture(appearance: .aqua)
        defer { light.cleanup() }
        light.view.prepareInitialPage(for: Self.youtube)
        #expect(light.cover == nil)

        let loaded = try Fixture()
        defer { loaded.cleanup() }
        loaded.view.loadHTMLString("<p>Already visible</p>", baseURL: Self.youtube)
        try await Self.waitUntil { loaded.view.url != nil && !loaded.view.isLoading }
        loaded.view.prepareInitialPage(for: Self.youtube)
        #expect(loaded.cover == nil)
    }

    @Test func leavingYouTubeStoppingAndChangingAppearanceRevealThePage() async throws {
        for action in ["navigate", "stop", "appearance"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            fixture.view.prepareInitialPage(for: Self.youtube)
            let cover = try #require(fixture.cover)
            fixture.load()
            try await fixture.waitForWhiteDocument()
            switch action {
            case "navigate":
                fixture.view.loadHTMLString("<p>Consent or another site</p>", baseURL: URL(string: "https://example.com/"))
            case "stop": fixture.view.stopLoading()
            default: fixture.view.appearance = NSAppearance(named: .aqua)
            }
            try await Self.waitUntil { cover.superview == nil }
        }
    }

    @Test func failedResourcesAndTimeoutCannotLeaveACoverStuck() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.view.prepareInitialPage(for: Self.youtube)
        let cover = try #require(fixture.cover)
        fixture.load()
        try await fixture.waitForWhiteDocument()
        fixture.resource.finishTransfers(sendingRemaining: false)
        try await Self.waitUntil { !fixture.view.isLoading && cover.superview == nil }

        let stalled = try Fixture()
        defer { stalled.cleanup() }
        let timeout = try #require(YouTubeStartupCover(webView: stalled.view, destination: Self.youtube,
                                                     maximumWait: .milliseconds(100)))
        #expect(timeout.superview === stalled.view)
        try await Self.waitUntil { timeout.superview == nil }
    }

    @Test func managerInstallsCoverBeforeTheNewPageLoadsAndDisposalRemovesIt() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.appearance = previous }
        let manager = WebViewManager(profileID: UUID(), ephemeral: true,
                                    faviconStore: FaviconStore { _, _, _ in nil }, observesMemoryPressure: false)
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: manager.profileID, title: "YouTube", currentURL: Self.youtube)
        let page = manager.prepare(tab)
        let cover = try #require(page.view.subviews.compactMap { $0 as? YouTubeStartupCover }.first)
        #expect(page.view.url == nil && !page.view.isLoading)
        manager.discardAll()
        #expect(cover.superview == nil)
    }

    @Test func coverDoesNotKeepADiscardedWebViewAlive() async throws {
        weak var released: BrowserWebView?
        weak var removed: YouTubeStartupCover?
        do {
            let fixture = try Fixture()
            defer { fixture.resource.stop() }
            fixture.view.prepareInitialPage(for: Self.youtube)
            released = fixture.view
            let cover = try #require(fixture.cover)
            removed = cover
        }
        try await Self.waitUntil { released == nil && removed == nil }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Synthetic HTML with one loopback-only image held halfway through loading.
    /// HTTPS pages cannot load our custom-scheme scripts as subresources.
    @MainActor private final class Fixture {
        let resource: LocalHTTPServer
        let view: BrowserWebView
        var cover: YouTubeStartupCover? { view.subviews.compactMap { $0 as? YouTubeStartupCover }.first }

        init(appearance: NSAppearance.Name = .darkAqua) throws {
            _ = NSApplication.shared
            let pixel = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
            resource = try LocalHTTPServer(body: pixel, initialChunk: 16)
            try #require(resource.port != 0)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = BrowserWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.appearance = NSAppearance(named: appearance)
        }

        func load() {
            view.loadSimulatedRequest(URLRequest(url: YouTubeStartupCoverTests.youtube), responseHTML: """
                <!doctype html><html><head><style>
                html { background-color: white !important; }
                html[dark] { background-color: #0f0f0f !important; }
                </style></head><body><p>Video page</p><img src="\(resource.url)"></body></html>
                """)
        }

        func waitForWhiteDocument() async throws {
            try await YouTubeStartupCoverTests.waitUntil {
                view.isLoading && view.url == YouTubeStartupCoverTests.youtube
                    && view.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent == 1
            }
            #expect(view.url == YouTubeStartupCoverTests.youtube)
        }

        func cleanup() { view.stopLoading(); resource.stop() }
    }
}
