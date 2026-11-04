// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
@testable import EarlyBrowser
import JavaScriptCore
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct InitialPagePresentationTests {
    @Test(arguments: [false, true])
    func paintObserverOnlyNotifiesOnceAfterContentOrItsUnsupportedFallback(supportsPaint: Bool) throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.messages = [];
            globalThis.listeners = {};
            globalThis.document = { addEventListener: (name, callback) => listeners[name] = callback };
            globalThis.addEventListener = document.addEventListener;
            globalThis.window = { webkit: { messageHandlers: {
                earlyInitialPaint: { postMessage: token => messages.push(token) }
            } } };
            globalThis.PerformanceObserver = class {
                static supportedEntryTypes = \(supportsPaint ? "['paint']" : "[]");
                constructor(callback) { globalThis.deliver = entries => callback({ getEntries: () => entries }); }
                observe(options) { globalThis.options = options; }
                disconnect() { globalThis.disconnected = true; }
            };
            """)
        context.evaluateScript(PagePaintObserver.script)
        try #require(context.exception == nil, "\(String(describing: context.exception))")
        #expect(context.evaluateScript("__earlyInitialPaint.ready")?.toBool() == false)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 0)
        if supportsPaint {
            #expect(context.evaluateScript("options.type === 'paint' && options.buffered === true")?.toBool() == true)
            context.evaluateScript("deliver([{name: 'first-paint'}])")
            #expect(context.evaluateScript("messages.length")?.toInt32() == 0, "A blank background paint must not reveal the page")
            context.evaluateScript("deliver([{name: 'first-contentful-paint'}]); deliver([{name: 'first-contentful-paint'}]);")
            #expect(context.evaluateScript("disconnected")?.toBool() == true)
        } else {
            context.evaluateScript("listeners.DOMContentLoaded(); listeners.DOMContentLoaded();")
        }
        try #require(context.exception == nil, "\(String(describing: context.exception))")
        #expect(context.evaluateScript("__earlyInitialPaint.ready")?.toBool() == true)
        #expect(context.evaluateScript("messages.length === 1 && messages[0] === __earlyInitialPaint.token")?.toBool() == true)
    }

    @Test(arguments: ["#0f0f0f", "#ffffff"])
    func onlyCurrentDocumentReadinessRevealsTheCoveredPageBeforeLoadingFinishes(color: String) async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let view = fixture.view
        #expect(view.alphaValue == 1 && fixture.host.hidesInitialPage)
        #expect(fixture.host.subviews.last !== view)
        #expect(fixture.host.subviews.last?.frame == view.frame)
        #expect(fixture.host.subviews.last?.alphaValue == 1, "The loading cover must completely hide the blank canvas")
        #expect(fixture.presentation.isReady == false)
        #expect(try await view.evaluateJavaScript("typeof globalThis.__earlyInitialPaint") as? String == "undefined")
        // Exercise the real isolated-world bridge without requiring the package
        // runner's unshown window to receive compositor paint-timing events.
        // Native UI tests verify actual first paint in a running application.
        try await fixture.signalReadiness(token: "old-document")
        #expect(!fixture.presentation.isReady)
        try await fixture.signalReadiness(ready: false)
        #expect(!fixture.presentation.isReady)

        _ = try await view.callAsyncJavaScript("document.documentElement.style.backgroundColor = color;",
                                             arguments: ["color": color], in: nil, contentWorld: .page)
        try await fixture.signalReadiness()
        try await Self.waitUntil { fixture.presentation.isReady }
        #expect(view.alphaValue == 1 && view.isLoading && !fixture.host.hidesInitialPage)
        #expect(try await view.evaluateJavaScript("document.documentElement.style.backgroundColor") as? String
                == (color == "#ffffff" ? "rgb(255, 255, 255)" : "rgb(15, 15, 15)"))
        #expect(try await view.evaluateJavaScript("globalThis.__earlyInitialPaint.ready", in: nil, contentWorld: PagePaintObserver.world) as? Bool == true)
        #expect(view.superview === fixture.host)

        // The same native view remains visible during later navigation.
        view.loadSimulatedRequest(URLRequest(url: URL(string: "https://another.invalid/")!), responseHTML: "<p>Next page</p>")
        try await Self.waitUntil { !view.isLoading && view.url?.host == "another.invalid" }
        #expect(view.alphaValue == 1 && fixture.presentation.isReady)
    }

    @Test func completedEmptyDocumentUsesRenderCompletionWithoutContentfulPaint() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        fixture.pages.finish()
        try await Self.waitUntil { !fixture.view.isLoading && fixture.presentation.isReady }
        #expect(fixture.view.alphaValue == 1)
        #expect(try await fixture.view.evaluateJavaScript("globalThis.__earlyInitialPaint.ready", in: nil, contentWorld: PagePaintObserver.world) as? Bool == false)
    }

    @Test(arguments: ["stop", "error", "process-ended"])
    func interruptedInitialLoadsAlwaysReveal(action: String) async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        switch action {
        case "stop": fixture.manager.stop(fixture.tab.id)
        case "error": fixture.manager.webView(fixture.view, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        default: fixture.manager.webViewWebContentProcessDidTerminate(fixture.view)
        }
        #expect(fixture.presentation.isReady && fixture.view.alphaValue == 1)
        if action == "process-ended" {
            fixture.presentation.begin()
            #expect(!fixture.presentation.isReady)
        }
    }

    @Test func hostAppearanceAndDetachmentPreserveNativeViewProperties() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let dark = try #require(fixture.host.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(dark.redComponent < 0.1)
        fixture.host.appearance = NSAppearance(named: .aqua)
        let light = try #require(fixture.host.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(light.redComponent > 0.5)
        fixture.view.alphaValue = 0.7
        fixture.host.frame.size = NSSize(width: 700, height: 500)
        #expect(fixture.view.frame == fixture.host.bounds && fixture.view.alphaValue == 0.7)
        #expect(fixture.host.hidesInitialPage)
        #expect(fixture.host.subviews.last?.frame == fixture.view.frame)
        #expect(fixture.host.display(nil))
        #expect(fixture.view.alphaValue == 0.7 && !fixture.host.hidesInitialPage)
        #expect(fixture.host.display(fixture.view))
        #expect(fixture.view.alphaValue == 0.7 && fixture.host.hidesInitialPage)
        fixture.presentation.reveal()
        #expect(!fixture.host.hidesInitialPage)
        fixture.host.frame.size.width += 10
        #expect(fixture.view.alphaValue == 0.7, "Do not interfere with native transitions after initial presentation")
    }

    @Test func anUnshownBackgroundPageDoesNotForceRendering() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.host.display(nil)
        fixture.view.loadSimulatedRequest(URLRequest(url: fixture.tab.currentURL), responseHTML: "<html></html>")
        try await Self.waitUntil { fixture.view.url != nil && !fixture.view.isLoading }
        #expect(!fixture.presentation.isReady && fixture.view.alphaValue == 1)
        fixture.host.display(fixture.view)
        try await Self.waitUntil { fixture.presentation.isReady }
        #expect(fixture.view.alphaValue == 1)
    }

    @Test(arguments: [false, true])
    func presentationRestoresPageFocusOnlyWhenTheLoadingHostStillOwnsIt(focusedElsewhere: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        fixture.host.canFocus = true
        #expect(fixture.host.pageFocusTarget === fixture.host)
        let other = FocusView()
        fixture.host.addSubview(other)
        #expect(fixture.window.makeFirstResponder(focusedElsewhere ? other : fixture.host))
        fixture.presentation.reveal()
        #expect(fixture.window.firstResponder === (focusedElsewhere ? other : fixture.view))
        #expect(fixture.host.pageFocusTarget === fixture.view)
    }

    @Test func aCompletedPageCanWaitForItsFirstUsableViewport() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.host.display(nil)
        fixture.view.frame = .zero
        fixture.host.frame = .zero
        fixture.view.loadSimulatedRequest(URLRequest(url: fixture.tab.currentURL), responseHTML: "<html></html>")
        try await Self.waitUntil { fixture.view.url != nil && !fixture.view.isLoading }
        fixture.host.display(fixture.view)
        #expect(!fixture.presentation.isReady)
        fixture.host.frame.size = NSSize(width: 400, height: 300)
        try await Self.waitUntil { fixture.presentation.isReady }
        #expect(fixture.view.alphaValue == 1)
    }

    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            try #require(ContinuousClock.now < deadline, sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private final class Fixture {
        let pages = PresentationPages()
        let manager: WebViewManager
        let tab: BrowserTab
        let view: WKWebView
        let host = WebContentView.HostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window: NSWindow
        var presentation: InitialPagePresentation { view.initialPagePresentation! }

        init() {
            _ = NSApplication.shared
            let profile = UUID()
            manager = WebViewManager(profileID: profile, ephemeral: true,
                                     input: NavigationInput(allowedSchemes: ["http", "https", "early-presentation"]),
                                     faviconStore: FaviconStore { _, _, _ in nil }, observesMemoryPressure: false) { [pages] in
                $0.setURLSchemeHandler(pages, forURLScheme: "early-presentation")
            }
            tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Fixture",
                             currentURL: URL(string: "early-presentation://fixture/page")!)
            view = manager.prepare(tab).view
            window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.display(view)
        }

        func start() async throws {
            manager.load(tab.currentURL, in: tab)
            try await InitialPagePresentationTests.waitUntil {
                view.isLoading && view.url == tab.currentURL && !manager.pages[tab.id]!.awaitsNavigationCommit
            }
            // Document readiness is independent of native background-color
            // propagation and the WindowServer visibility of the test process.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while try await view.evaluateJavaScript("document.body?.dataset.presentationFixture === 'ready'") as? Bool != true {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func signalReadiness(token: String? = nil, ready: Bool = true) async throws {
            _ = try await view.callAsyncJavaScript("""
                const state = globalThis.__earlyInitialPaint;
                state.ready = ready;
                window.webkit.messageHandlers.earlyInitialPaint.postMessage(token ?? state.token);
                """, arguments: ["token": token as Any? ?? NSNull(), "ready": ready],
                in: nil, contentWorld: PagePaintObserver.world)
            // Drain the bridge's document-validation evaluation before checking
            // rejection. This does not force rendering or synthesize user input.
            _ = try await view.evaluateJavaScript("0", in: nil, contentWorld: PagePaintObserver.world)
        }
        func cleanup() { host.invalidate(); manager.discardAll(); window.close() }
    }
}

/// Serve an empty document and explicitly hold its completion. No sockets,
/// rendering heuristics, pending subresources or visible test windows required.
@MainActor private final class PresentationPages: NSObject, WKURLSchemeHandler {
    private var pending: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let data = Data("""
            <!doctype html><html><head><style>html{background:white}</style></head>
            <body data-presentation-fixture="ready"></body></html>
            """.utf8)
        pending[ObjectIdentifier(task)] = task
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
    }

    func finish() {
        let tasks = Array(pending.values)
        pending.removeAll()
        tasks.forEach { $0.didFinish() }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(task))
    }
}
