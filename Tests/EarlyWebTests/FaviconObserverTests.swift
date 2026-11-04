// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import JavaScriptCore
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct FaviconScriptTests {
    @Test func selectionUsesMatchingMediaAndLastDeclaredIcon() throws {
        let context = try harness()
        context.evaluateScript("""
            links = [icon('fallback.png'), icon('light.png', '(prefers-color-scheme: light)'),
                     icon('dark.png', '(prefers-color-scheme: dark)'), icon('print.png', 'print')];
            """)
        #expect(try selection(context) == ["light.png", "fallback.png"])
        context.evaluateScript("dark = true")
        #expect(try selection(context) == ["dark.png", "fallback.png"])
    }

    @Test func lateMutationsAndAppearanceChangesNotifyWithoutReloading() throws {
        let context = try harness()
        context.evaluateScript("links = [icon('initial.png')]")
        context.evaluateScript(FaviconObserver.script)
        context.evaluateScript("flush()")
        try check(context)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 1)
        context.evaluateScript("links[0].href = 'late.png'; mutate(document.head); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 2)
        #expect(try selection(context) == ["late.png"])
        context.evaluateScript("mutate(document.head); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 2, "Unrelated head mutations do not refetch icons")
        context.evaluateScript("dark = true; changeMedia(); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 3, "An unchanged URL can have a different appearance")
        context.evaluateScript("links = []; mutate(document.head); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 4)
        #expect(try selection(context).isEmpty)
        try check(context)
    }

    @Test func replacedHeadsAndBackForwardRestorationReconnectAndPageHideStopsWork() throws {
        let context = try harness()
        context.evaluateScript("links = [icon('initial.png')]")
        context.evaluateScript(FaviconObserver.script)
        context.evaluateScript("flush(); document.head = { querySelectorAll: () => links }; links = [icon('replacement.png')]; mutate(document.documentElement); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 2)
        context.evaluateScript("listeners.pagehide(); links[0].href = 'hidden.png'; mutate(document.head); dark = true; changeMedia(); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 2)
        context.evaluateScript("listeners.pageshow(); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 3)
        context.evaluateScript("links[0].href = 'restored.png'; mutate(document.head); flush()")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 4)
        try check(context)
    }

    private func selection(_ context: JSContext) throws -> [String] {
        let value = context.evaluateScript(FaviconObserver.discoveryScript)?.toDictionary()
        try check(context)
        return try #require(value?["links"] as? [String])
    }

    private func check(_ context: JSContext) throws {
        try #require(context.exception == nil, "\(String(describing: context.exception))")
    }

    private func harness() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var links = [], dark = false, messages = [], listeners = {}, timers = new Map(), nextTimer = 0;
            var observers = [], mediaQueries = [];
            var icon = (href, media = '') => ({ href, media });
            var document = { head: { querySelectorAll: () => links }, documentElement: {} };
            var window = { addEventListener: (name, callback) => listeners[name] = callback,
                webkit: { messageHandlers: { earlyFavicon: { postMessage: value => messages.push(value) } } } };
            function setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; }
            function clearTimeout(id) { timers.delete(id); }
            function flush() { const pending = Array.from(timers.values()); timers.clear(); pending.forEach(callback => callback()); }
            function matchMedia(text) {
                const handlers = new Set();
                const query = { get matches() { return text.includes('dark') ? dark : text.includes('light') ? !dark : text !== 'print'; },
                    addEventListener: (_, callback) => handlers.add(callback),
                    removeEventListener: (_, callback) => handlers.delete(callback),
                    change: () => Array.from(handlers).forEach(callback => callback()) };
                mediaQueries.push(query);
                return query;
            }
            function changeMedia() { Array.from(mediaQueries).forEach(query => query.change()); }
            var MutationObserver = class {
                constructor(callback) { this.callback = callback; this.target = null; observers.push(this); }
                observe(target) { this.target = target; }
                disconnect() { this.target = null; }
            };
            function mutate(target) { observers.filter(observer => observer.target === target).forEach(observer => observer.callback([])); }
            """)
        try check(context)
        return context
    }
}

@Suite(.serialized) @MainActor
struct FaviconObserverTests {
    @Test func livePageTracksLateIconsHeadReplacementAndRemoval() async throws {
        let fixture = FaviconPageFixture()
        defer { fixture.manager.discardAll() }
        try await fixture.open("<link id='icon' rel='icon' href='/initial.png'>")
        try await fixture.waitFor("/initial.png")
        let generation = fixture.page.navigationGeneration
        _ = try await fixture.page.view.evaluateJavaScript("document.querySelector('#icon').href = '/late.png'")
        try await fixture.waitFor("/late.png")
        _ = try await fixture.page.view.evaluateJavaScript("""
            const head = document.createElement('head');
            head.innerHTML = '<link rel="icon" href="/replacement.png">';
            document.head.replaceWith(head);
            """)
        try await fixture.waitFor("/replacement.png")
        _ = try await fixture.page.view.evaluateJavaScript("document.head.querySelector('link').remove()")
        try await fixture.waitFor("/favicon.ico")
        #expect(fixture.page.navigationGeneration == generation)
        #expect(fixture.manager.creationCount == 1)
    }

    @Test func mediaSelectionFollowsWebViewAppearanceWithoutReload() async throws {
        let fixture = FaviconPageFixture()
        defer { fixture.manager.discardAll() }
        fixture.page.view.appearance = NSAppearance(named: .darkAqua)
        try await fixture.open("""
            <link rel='icon' href='/light.png' media='(prefers-color-scheme: light)'>
            <link rel='icon' href='/dark.png' media='(prefers-color-scheme: dark)'>
            <link rel='icon' href='/print.png' media='print'>
            """)
        try await fixture.waitFor("/dark.png")
        #expect(await fixture.probe.paths.contains("/light.png") == false)
        let generation = fixture.page.navigationGeneration
        fixture.page.view.appearance = NSAppearance(named: .aqua)
        try await fixture.waitFor("/light.png")
        #expect(fixture.page.navigationGeneration == generation)
        #expect(fixture.manager.creationCount == 1)
    }
}

@MainActor
private final class FaviconPageFixture {
    let manager: WebViewManager
    let page: BrowserPage
    let url = URL(string: "https://fixture.invalid/page")!
    let probe: PageIconProbe

    init() {
        _ = NSApplication.shared
        let probe = PageIconProbe()
        self.probe = probe
        let profile = UUID()
        manager = WebViewManager(profileID: profile, ephemeral: true,
            faviconStore: FaviconStore { _, urls, _ in await probe.record(urls); return nil }, observesMemoryPressure: false)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Icons", currentURL: url)
        page = manager.prepare(tab)
    }

    func open(_ head: String) async throws {
        page.view.loadHTMLString("<!doctype html><head>\(head)</head><body>Icons</body>", baseURL: url)
        try await waitForFavicon("document load") { self.page.view.url == self.url && !self.page.view.isLoading }
    }

    func waitFor(_ path: String) async throws {
        try await waitForFavicon(path) { await self.probe.paths.contains(path) }
    }
}

private actor PageIconProbe {
    var paths: [String] = []
    func record(_ urls: [URL]) { if let first = urls.first { paths.append(first.path) } }
}
