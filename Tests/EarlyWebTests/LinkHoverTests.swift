// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Testing
import WebKit

/// WebKit delivers pointer moves only to an on-screen window, so real hovering
/// is covered by the native UI suite. These check the bridge and its filter.
@Suite(.serialized) @MainActor
struct LinkHoverTests {
    @Test func onlyOpenableAddressesAreShownAndNavigationClearsThePreview() async throws {
        let fixture = PageToolFixture(pages: ["links": "<a href='/next'>Next</a>", "other": "<p>Other</p>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("links")
        let manager = fixture.manager
        let page = try fixture.page(tab)
        let scripts = page.view.configuration.userContentController.userScripts
        #expect(scripts.contains { $0.source == LinkHoverObserver.script && !$0.isForMainFrameOnly })

        manager.updateLinkHover(in: page.view, href: fixture.url("next?item=1").absoluteString, avoidsCorner: true)
        #expect(page.hoveredLink == LinkHover(url: fixture.url("next?item=1"), avoidsLeadingCorner: true))
        manager.updateLinkHover(in: page.view, href: "mailto:hello@example.com", avoidsCorner: false)
        #expect(page.hoveredLink?.url.absoluteString == "mailto:hello@example.com")
        for rejected in ["javascript:alert(1)", "ftp://example.com/file", "data:text/html,hi",
                         "https://example.com/" + String(repeating: "a", count: 2100)] {
            manager.updateLinkHover(in: page.view, href: rejected, avoidsCorner: false)
            #expect(page.hoveredLink == nil, "\(rejected.prefix(40)) is never shown")
        }
        manager.updateLinkHover(in: page.view, href: "https://example.com/a", avoidsCorner: false)
        manager.updateLinkHover(in: page.view, href: nil, avoidsCorner: false)
        #expect(page.hoveredLink == nil, "Leaving the link clears it")

        // A view the manager does not own cannot set a preview.
        let foreign = WKWebView(frame: .zero)
        manager.updateLinkHover(in: foreign, href: "https://example.com/a", avoidsCorner: false)
        #expect(page.hoveredLink == nil)

        manager.updateLinkHover(in: page.view, href: "https://example.com/a", avoidsCorner: false)
        manager.load(fixture.url("other"), in: tab)
        try await fixture.waitUntil("navigate") { page.view.url == fixture.url("other") && !page.isLoading }
        #expect(page.hoveredLink == nil, "A new document starts without a preview")
    }
}
