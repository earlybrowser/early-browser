// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
@testable import EarlyBrowser
import Network
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct InitialPagePresentationTests {
    @Test(arguments: ["#0f0f0f", "#ffffff"])
    func blankCanvasWaitsForContentAndRevealsBeforeLoadingFinishes(color: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let view = fixture.view
        _ = try await view.takeSnapshot(configuration: nil)
        #expect(view.alphaValue == 0)
        #expect(fixture.presentation.isReady == false)
        #expect(try await view.evaluateJavaScript("typeof globalThis.__earlyInitialPaint") as? String == "undefined")
        // An old isolated document's queued notification is insufficient.
        _ = try await view.evaluateJavaScript("window.webkit.messageHandlers.earlyInitialPaint.postMessage('old-document'); true",
                                             in: nil, contentWorld: PagePaintObserver.world)
        _ = try await view.takeSnapshot(configuration: nil)
        #expect(!fixture.presentation.isReady)

        _ = try await view.evaluateJavaScript("""
            document.documentElement.style.backgroundColor = '\(color)';
            document.body.innerHTML += '<h1>First content</h1>';
            """)
        _ = try await view.takeSnapshot(configuration: nil)
        try await Self.waitUntil { fixture.presentation.isReady }
        #expect(view.alphaValue == 1 && view.isLoading)
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
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        fixture.server.finish()
        try await Self.waitUntil { !fixture.view.isLoading && fixture.presentation.isReady }
        #expect(fixture.view.alphaValue == 1)
        #expect(try await fixture.view.evaluateJavaScript("globalThis.__earlyInitialPaint.ready", in: nil, contentWorld: PagePaintObserver.world) as? Bool == false)
    }

    @Test(arguments: ["stop", "error", "process-ended"])
    func interruptedInitialLoadsAlwaysReveal(action: String) async throws {
        let fixture = try Fixture()
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
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let dark = try #require(fixture.host.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(dark.redComponent < 0.1)
        fixture.host.appearance = NSAppearance(named: .aqua)
        let light = try #require(fixture.host.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(light.redComponent > 0.5)
        fixture.host.frame.size = NSSize(width: 700, height: 500)
        #expect(fixture.view.frame == fixture.host.bounds && fixture.view.alphaValue == 0)
        #expect(fixture.host.display(nil))
        #expect(fixture.view.alphaValue == 1)
        #expect(fixture.host.display(fixture.view))
        #expect(fixture.view.alphaValue == 0)
        fixture.presentation.reveal()
        fixture.view.alphaValue = 0.7
        fixture.host.frame.size.width += 10
        #expect(fixture.view.alphaValue == 0.7, "Do not interfere with native transitions after initial presentation")
    }

    @Test func anUnshownBackgroundPageDoesNotForceRendering() async throws {
        let fixture = try Fixture()
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
        let fixture = try Fixture()
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
        let fixture = try Fixture()
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

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private final class Fixture {
        let server: PaintHTTPServer
        let manager: WebViewManager
        let tab: BrowserTab
        let view: WKWebView
        let host = WebContentView.HostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window: NSWindow
        var presentation: InitialPagePresentation { view.initialPagePresentation! }

        init() throws {
            _ = NSApplication.shared
            server = try PaintHTTPServer()
            let profile = UUID()
            manager = WebViewManager(profileID: profile, ephemeral: true,
                                     faviconStore: FaviconStore { _, _, _ in nil }, observesMemoryPressure: false)
            tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Fixture", currentURL: server.url)
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
                    && view.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent == 1
            }
        }
        func cleanup() { host.invalidate(); manager.discardAll(); window.close(); server.stop() }
    }
}

/// Stream an empty HTML body, then hold EOF until the test completes it. This
/// avoids version-dependent painting and loading of hidden image subresources.
private final class PaintHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "early.tests.paint.http")
    private var connections: [NWConnection] = []
    private let prefix = Data(("<!doctype html><html><head><style>html{background:white}</style></head><body><!--"
        + String(repeating: " ", count: 8192) + "-->").utf8)
    private let suffix = Data("</body></html>".utf8)
    private var port: UInt16 = 0
    var url: URL { URL(string: "http://127.0.0.1:\(port)/page")! }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
                guard let self else { return }
                var data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(self.prefix.count + self.suffix.count)\r\nConnection: close\r\n\r\n".utf8)
                data.append(self.prefix)
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let boundPort = listener.port else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        port = boundPort.rawValue
    }
    func finish() {
        queue.async {
            for connection in self.connections {
                connection.send(content: self.suffix, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func stop() { queue.sync { connections.forEach { $0.cancel() }; connections = [] }; listener.cancel() }
}
