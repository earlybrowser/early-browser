// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Testing
import WebKit
@testable import EarlyWeb

@Suite(.serialized) @MainActor
struct PageSourceCacheTests {
    private func page(_ value: Int) -> URL { URL(string: "https://source.invalid/\(value)")! }
    private func source(_ value: Int) -> URL { NavigationInput.sourceURL(of: page(value))! }

    @Test func inactiveSourcesAreBoundedByBytesAndCountAndReplacementAccountingIsExact() {
        let cache = PageSourcePages(inactiveByteLimit: 1024)
        for value in 0..<30 { cache.store(String(repeating: "x", count: 50), title: "", for: page(value)) }
        #expect(cache.snapshotCount == 20 && cache.retainedBytes == 1000 && cache.inactiveBytes == 1000)
        #expect(!cache.contains(page(0)) && cache.contains(page(29)))
        cache.store("é", title: "Title", for: page(29))
        #expect(cache.retainedBytes == 957)
        cache.store(String(repeating: "y", count: 2048), title: "", for: page(100))
        #expect(cache.retainedBytes <= 1024 && !cache.contains(page(100)))
        cache.clear()
        #expect(cache.retainedBytes == 0 && cache.snapshotCount == 0)
    }

    @Test func activeSourcesAreNeverTruncatedAndTwentyUnusedLargePagesDoNotStayResident() {
        let cache = PageSourcePages()
        let ids = (0..<20).map { _ in UUID() }
        for value in 0..<20 {
            cache.navigate(tab: ids[value], to: source(value))
            cache.store(String(repeating: "x", count: 5 * 1024 * 1024) + String(value), title: "", for: page(value))
        }
        #expect(cache.activeUsers == 20 && cache.retainedBytes > 100 * 1024 * 1024)
        #expect(cache.inactiveBytes == 0 && cache.snapshotCount == 20)
        for id in ids { cache.release(tab: id) }
        #expect(cache.activeUsers == 0 && cache.retainedBytes <= PageSourcePages.inactiveByteLimit)
        print("View Source retained bytes after closing twenty 5 MiB sources: \(cache.retainedBytes) (previous cache: over 100 MiB)")
        cache.dropInactive()
        #expect(cache.retainedBytes == 0)
    }

    @Test func sharedSourcesSurviveOneTabLeavingAndCaptureLeasesAlwaysRelease() {
        let cache = PageSourcePages(inactiveByteLimit: 16)
        let lease = cache.lease(page(1))
        cache.store(String(repeating: "a", count: 1000), title: "", for: page(1))
        #expect(cache.contains(page(1)), "Even an oversized captured page survives until the opener registers its tab")
        let first = UUID(), second = UUID()
        cache.navigate(tab: first, to: source(1)); cache.navigate(tab: second, to: source(1))
        cache.releaseLease(lease)
        cache.navigate(tab: first, to: page(2))
        #expect(cache.activeUsers == 1 && cache.contains(page(1)))
        cache.release(tab: second)
        #expect(!cache.contains(page(1)) && cache.retainedBytes == 0)
        let failed = cache.lease(page(2))
        cache.store(String(repeating: "z", count: 1000), title: "", for: page(2))
        cache.releaseLease(failed)
        #expect(!cache.contains(page(2)))
    }

    @Test func metadataKeepsEvictedOpenSourceTabsButClosedPinsReleaseTheirOwnership() {
        let cache = PageSourcePages(inactiveByteLimit: 1)
        let profile = UUID(), space = UUID()
        let open = BrowserTab(spaceID: space, profileID: profile, title: "Source", currentURL: source(1))
        cache.reconcile([open])
        cache.store("Complete source", title: "", for: page(1))
        #expect(cache.activeUsers == 1 && cache.contains(page(1)))
        var closed = open; closed.isOpen = false
        cache.reconcile([closed])
        #expect(cache.activeUsers == 0 && !cache.contains(page(1)))
    }

    @Test func renderingEscapesOnceAndPreservesUnicodeAndFullMarkup() {
        let markup = "<script>alert(\"x\")</script> & <\u{301} é 🪐"
        let expected = "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &lt;\u{301} é 🪐"
        #expect(PageSourcePages.escape(markup) == expected)
        let html = PageSourcePages.render(markup, title: "A <B>", page: page(1))
        #expect(html.contains("<title>Source of A &lt;B&gt;</title>"))
        #expect(html.contains("<pre>" + expected + "</pre>"))
        #expect(!html.contains("<script>"))
    }

    @Test func anOversizedSourceOpensAndReloadsWithoutRefetchAndReleasesOnClose() async throws {
        let count = 9 * 1024 * 1024
        // Keep the real nine-MiB payload, using ordinary source lines. A single
        // nine-million-character word stresses WebKit's line breaker rather
        // than the snapshot cache and can stall an unshown view's layout.
        let line = String(repeating: "x", count: 255) + "\n"
        let text = String(repeating: line, count: count / line.utf8.count)
        let fixture = PageToolFixture(pages: ["large": "<!doctype html><title>Large</title><pre>" + text + "END</pre>"])
        defer { fixture.cleanup() }
        let original = try await fixture.open("large")
        var opened: BrowserTab?
        #expect(await fixture.manager.openPageSource(original.id) { address in
            let tab = BrowserTab(spaceID: UUID(), profileID: fixture.profile, title: "Source", currentURL: address)
            opened = tab
            fixture.manager.reconcile(tabs: fixture.tabs + [tab])
            fixture.manager.prepare(tab).view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            fixture.manager.load(address, in: tab)
            return true
        })
        let tab = try #require(opened)
        do {
            try await fixture.waitUntil("oversized source load") {
                fixture.manager.pages[tab.id]?.view.title == "Source of Large" && fixture.manager.pages[tab.id]?.isLoading == false
            }
        } catch {
            let page = fixture.manager.pages[tab.id]
            Issue.record("Source load state: title=\(page?.view.title ?? "nil"), loading=\(page?.view.isLoading ?? false), failure=\(page?.failure ?? "nil"), cachedBytes=\(fixture.manager.sourcePages.retainedBytes), owners=\(fixture.manager.sourcePages.activeUsers)")
            throw error
        }
        #expect(try await fixture.evaluate("document.querySelector('pre').textContent.length", in: tab) as? Int ?? 0 > count)
        #expect(try await fixture.evaluate("document.scripts.length", in: tab) as? Int == 0)
        #expect(fixture.manager.sourcePages.retainedBytes > PageSourcePages.inactiveByteLimit)
        fixture.manager.reload(tab.id)
        try await fixture.waitUntil("source reload") { fixture.manager.pages[tab.id]?.view.isLoading == false }
        #expect(try await fixture.evaluate("document.querySelector('pre').textContent.includes('END')", in: tab) as? Bool == true)
        fixture.manager.discard(tabID: tab.id)
        #expect(fixture.manager.sourcePages.activeUsers == 0 && fixture.manager.sourcePages.retainedBytes == 0)
        fixture.cleanup()
        #expect(fixture.manager.sourcePages.snapshotCount == 0)
    }
}
