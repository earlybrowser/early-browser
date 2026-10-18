// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Network
import Testing
import WebKit

@Suite @MainActor
struct BrowserIdentityIntegrationTests {
    @Test func generatedIdentityMatchesHTTPAndJavaScriptIncludingPopupInheritance() async throws {
        _ = NSApplication.shared
        let server = try IdentityHTTPServer()
        defer { server.stop() }
        try await waitUntil("listener startup") { server.isReady && (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port?.rawValue)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        _ = try NavigationInput().validate(base)
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true) {
            // This fixture opens its popup programmatically; production policy
            // still requires a user gesture (also covered by the native UI test).
            $0.preferences.javaScriptCanOpenWindowsAutomatically = true
        }
        var notices: [String] = []
        manager.onNotice = { notices.append($0) }
        defer {
            manager.onNewWindow = nil
            manager.discardAll()
        }
        func tab(_ path: String) -> BrowserTab {
            BrowserTab(spaceID: UUID(), profileID: profile, title: "Identity",
                       currentURL: base.appendingPathComponent(path))
        }
        let source = tab("redirect")
        manager.load(source.currentURL, in: source)
        let first = try #require(manager.existingView(for: source.id))
        let identity: String
        do {
            identity = try await readIdentity(first)
        } catch {
            Issue.record("Initial identity load: url=\(String(describing: first.url)), loading=\(first.isLoading), failure=\(manager.pages[source.id]?.failure ?? "none"), notices=\(notices), requests=\(server.requests)")
            throw error
        }
        #expect(identity.hasSuffix(BrowserUserAgent.applicationName))
        #expect(first.customUserAgent?.isEmpty != false)
        #expect(manager.prepare(source).view === first)

        let background = tab("identity")
        manager.load(background.currentURL, in: background)
        let second = try #require(manager.existingView(for: background.id))
        #expect(try await readIdentity(second) == identity)

        var popup: WKWebView?
        manager.onNewWindow = { url, supplied in
            // Inspect the actual configuration from WebKit, not a test-created
            // approximation. Its UA and data store must already be inherited.
            #expect(supplied.applicationNameForUserAgent == BrowserUserAgent.applicationName)
            #expect(supplied.websiteDataStore === first.configuration.websiteDataStore)
            let popupTab = BrowserTab(spaceID: source.spaceID, profileID: profile,
                                      title: "Popup", currentURL: url)
            let view = manager.prepare(popupTab, configuration: supplied).view
            #expect(view.customUserAgent?.isEmpty != false)
            popup = view
            return view
        }
        _ = try await first.evaluateJavaScript("document.getElementById('popup').click()")
        try await waitUntil("popup creation") { popup != nil }
        let opened = try #require(popup)
        #expect(try await readIdentity(opened) == identity)
        try await waitUntil("three image requests") { server.requests.filter { $0.path == "/pixel" }.count == 3 }
        #expect(server.requests.contains { $0.path == "/redirect" })
        #expect(server.requests.filter { $0.path == "/identity" }.count == 3)
        // The favicon service uses a separate cookie-free URLSession, not a
        // WKWebView. Verify every document, redirect and page subresource here.
        let webRequests = server.requests.filter { ["/redirect", "/identity", "/pixel"].contains($0.path) }
        #expect(webRequests.allSatisfy { $0.agent == identity }, "Expected \(identity); received \(webRequests)")
        #expect(manager.creationCount == 3)
    }

    private func readIdentity(_ view: WKWebView) async throws -> String {
        // Wait for the requested document before evaluating page-owned values.
        // Evaluating on the initial empty view can race its first navigation.
        try await waitUntil("identity navigation") { view.url?.path == "/identity" && !view.isLoading }
        var values: [String] = []
        try await waitUntil("page-owned identity values") {
            values = (try? await view.evaluateJavaScript(
                "[document.getElementById('server-agent')?.textContent ?? '', document.getElementById('script-agent')?.textContent ?? '']")) as? [String] ?? []
            return values.count == 2 && !values[0].isEmpty && !values[1].isEmpty
        }
        #expect(values[0] == values[1])
        return values[1]
    }

    private func waitUntil(_ stage: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw IdentityHTTPServer.Failure.timeout(stage) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// Loopback-only server: verifies real HTTP headers, including the redirect and
/// subresource paths. Page-owned JS reads navigator; no UA patch is injected.
@MainActor
private final class IdentityHTTPServer {
    enum Failure: Error { case timeout(String) }
    let listener: NWListener
    private(set) var isReady = false
    private var connections: [NWConnection] = []
    private(set) var requests: [(path: String, agent: String)] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.isReady = state == .ready }
        }
        listener.newConnectionHandler = { [weak self] connection in
            // All Network callbacks below run on the explicitly selected queue.
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffer: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var bytes = buffer
                bytes.append(data ?? Data())
                guard error == nil, bytes.count <= 32_768 else { connection.cancel(); return }
                let header = String(decoding: bytes, as: UTF8.self)
                if header.contains("\r\n\r\n") {
                    self.respond(connection, header: header)
                } else if complete {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: bytes)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }?
            .dropFirst("user-agent:".count).trimmingCharacters(in: .whitespaces) ?? ""
        requests.append((path, agent))
        let escaped = agent.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><meta charset="utf-8"><p id="server-agent">\(escaped)</p><p id="script-agent"></p>
        <a id="popup" href="/identity" target="_blank">Popup</a><img src="/pixel">
        <script>document.getElementById('script-agent').textContent = navigator.userAgent;</script>
        """
        let body = Data((path == "/identity" ? html : "").utf8)
        let status = path == "/redirect" ? "302 Found\r\nLocation: /identity" : "200 OK"
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                connection.cancel()
                self?.connections.removeAll { $0 === connection }
            }
        })
    }
}
