// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Foundation
import Network
import Testing
import WebKit

/// Extensions through WebKit's own support, with small test extensions and a
/// loopback web server; nothing leaves this Mac. Needs macOS 15.4.
@Suite(.serialized) @MainActor
struct BrowserExtensionTests {
    @Test func anExtensionRunsOnItsProfilesPages() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.runsOnPages()
    }

    @Test func whenClickedReachesOnlyAllowedSites() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.siteAccess()
    }

    @Test func anExtensionsOwnPagesOpenInTabs() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.ownPages()
    }

    @Test func websitesCannotOpenProtectedExtensionPages() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.protectedPages()
    }

    @Test func turningOneBlockerOffKeepsTheOthersBlocking() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.blockersStayOn()
    }

    @Test func privateWindowsGetOnlyExtensionsAllowedThere() async throws {
        guard #available(macOS 15.4, *) else { return }
        try await ExtensionScenarios.privateWindows()
    }

    @Test func safariExtensionsAreFoundInsideMacApps() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyApps-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        func appex(_ app: String, _ name: String, point: String, manifest: Bool = true, in parent: URL) throws {
            let plugin = parent.appending(path: "\(app).app/Contents/PlugIns/\(name).appex/Contents")
            try FileManager.default.createDirectory(at: plugin.appending(path: "Resources"), withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": "com.example.\(name)", "NSExtension": ["NSExtensionPointIdentifier": point]]
            info.write(to: plugin.appending(path: "Info.plist"), atomically: true)
            if manifest { try Data("{}".utf8).write(to: plugin.appending(path: "Resources/manifest.json")) }
        }
        try appex("Blocker", "BlockerExtension", point: "com.apple.Safari.web-extension", in: folder)
        try appex("Share", "ShareExtension", point: "com.apple.share-services", in: folder)
        try appex("Broken", "NoManifest", point: "com.apple.Safari.web-extension", manifest: false, in: folder)
        try appex("Nested", "NestedExtension", point: "com.apple.Safari.web-extension", in: folder.appending(path: "Utilities"))
        let found = BrowserExtensions.discover(in: [folder])
        #expect(found.map(\.bundleIdentifier) == ["com.example.BlockerExtension", "com.example.NestedExtension"],
                "Only Safari Web Extensions with a manifest, also in subfolders")
        #expect(found.first?.appName == "Blocker")
    }

    @Test func webKitSeesEveryDelegateMethod() throws {
        guard #available(macOS 15.4, *) else { return }
        let host = ExtensionHost(catalog: ExtensionCatalog(fileURL: nil), filesDirectory: nil,
                                 websiteDataStore: .nonPersistent(), storageIdentifier: nil, isPrivate: false)
        for selector in ["webExtensionController:openWindowsForExtensionContext:",
                         "webExtensionController:focusedWindowForExtensionContext:",
                         "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:",
                         "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:",
                         "webExtensionController:openOptionsPageForExtensionContext:completionHandler:",
                         "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:",
                         "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:",
                         "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:",
                         "webExtensionController:didUpdateAction:forExtensionContext:",
                         "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:"] {
            #expect(host.responds(to: NSSelectorFromString(selector)), "\(selector)")
        }
    }
}

/// The scenarios, on WebKit's extension support.
@available(macOS 15.4, *)
@MainActor
enum ExtensionScenarios {
    /// The tabs of a fixture, as a window would describe them.
    @MainActor final class Owner: ExtensionTabsOwner {
        let manager: WebViewManager
        var tabs: [BrowserTab] = []
        var active: UUID?
        init(_ manager: WebViewManager) { self.manager = manager }
        var extensionTabIDs: [UUID] { tabs.map(\.id) }
        var extensionActiveTabID: UUID? { active }
        func extensionTabState(_ id: UUID) -> ExtensionTabState? {
            let page = manager.pages[id]
            return ExtensionTabState(url: page?.view.url, title: page?.view.title, isPinned: false, isMuted: false,
                                     isPlayingAudio: false, isLoadingComplete: page?.isLoading == false)
        }
        func extensionWebView(_ id: UUID) -> WKWebView? { manager.pages[id]?.view }
        func extensionActivate(_ id: UUID) { active = id }
        func extensionClose(_ id: UUID) {}
        func extensionLoad(_ url: URL, in id: UUID) {}
        func extensionReload(_ id: UUID) { manager.reload(id) }
        func extensionGoBack(_ id: UUID) {}
        func extensionGoForward(_ id: UUID) {}
        func extensionSetMuted(_ muted: Bool, _ id: UUID) {}
        var extensionWindowFrame: CGRect { .zero }
        func extensionFocusWindow() {}
        func extensionCloseWindow() {}
    }

    /// A manager, its extension host and window, on one website data store.
    @MainActor struct Setup {
        let manager: WebViewManager
        let host: ExtensionHost
        let owner: Owner
        let window: ExtensionWindow
        let files: URL
        let profile = UUID()

        /// A regular profile's pages are on a persistent store, as in Early.
        /// WebKit treats pages on a memory-only store as private browsing,
        /// where (on macOS 26) extensions run only if allowed in private
        /// windows. One store is reused, and emptied after each test.
        static let profileStore = UUID(uuidString: "E4A1E5C0-7E57-4E57-A000-000000000001")!

        init(isPrivate: Bool = false, catalog: ExtensionCatalog = ExtensionCatalog(fileURL: nil)) {
            _ = NSApplication.shared
            files = FileManager.default.temporaryDirectory.appending(path: "EarlyExtensions-\(UUID())", directoryHint: .isDirectory)
            let store = isPrivate ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: Self.profileStore)
            let input = NavigationInput(allowedSchemes: Set(["http", "https"]).union(NavigationInput.extensionSchemes))
            manager = WebViewManager(profileID: profile, ephemeral: true, input: input,
                                     faviconStore: FaviconStore { _, _, _ in nil }, websiteDataStore: store,
                                     observesMemoryPressure: false)
            host = ExtensionHost(catalog: catalog, filesDirectory: files, websiteDataStore: store, storageIdentifier: nil,
                                 isPrivate: isPrivate)
            manager.extensionController = host.controller
            let extensionHost = host
            manager.extensionPageConfiguration = { extensionHost.pageConfiguration(for: $0) }
            owner = Owner(manager)
            window = ExtensionWindow(owner: owner, isPrivate: isPrivate)
            let tabsOwner = owner, webViews = manager
            manager.onNeedsNewView = { [weak tabsOwner, weak webViews] id, url in
                guard let tab = tabsOwner?.tabs.first(where: { $0.id == id }) else { return }
                webViews?.load(url, in: tab)
            }
            host.register(window)
            host.focus(window)
        }

        func open(_ url: URL) async throws -> BrowserTab {
            let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page", currentURL: url)
            owner.tabs.append(tab)
            owner.active = tab.id
            manager.reconcile(tabs: owner.tabs)
            manager.setPresentation(visibleTabIDs: [tab.id], focusedTabID: tab.id)
            manager.prepare(tab).view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            window.sync()
            manager.load(url, in: tab)
            try await waitUntil("load") { manager.pages[tab.id]?.isLoading == false && manager.pages[tab.id]?.view.url != nil }
            return tab
        }

        func cleanup() {
            // Unload before the host goes, as Early does when a private
            // session ends or a profile is deleted. Dropping a controller
            // with extensions loaded makes WebKit (macOS 26) trap later, as
            // its process pool is torn down.
            host.unloadAll()
            manager.discardAll()
            window.close()
            try? FileManager.default.removeItem(at: files)
            let store = manager.websiteDataStore
            if store.isPersistent {
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
        }
    }

    static func waitUntil(_ label: String, seconds: Double = 15, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw PageToolFixture.Failure.timeout(label) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func attribute(_ name: String, in view: WKWebView?) async -> String? {
        try? await view?.evaluateJavaScript("document.documentElement.getAttribute('\(name)')") as? String
    }

    /// Writes an extension's files into a new folder.
    static func extensionFolder(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyTestExtension-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appending(path: name)) }
        return folder
    }

    static func messenger(name: String = "Early Test", hosts: String = #"["<all_urls>"]"#) throws -> URL {
        try extensionFolder([
            "manifest.json": """
                {"manifest_version": 3, "name": "\(name)", "version": "1.2", "description": "Test",
                 "background": {"scripts": ["background.js"], "persistent": false},
                 "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
                 "action": {"default_popup": "popup.html", "default_title": "Test"},
                 "permissions": ["storage", "tabs"], "host_permissions": \(hosts)}
                """,
            "background.js": """
                browser.runtime.onMessage.addListener(async (message, sender) => {
                    await browser.action.setBadgeText({ text: '7', tabId: sender.tab.id });
                    await browser.storage.local.set({ seen: 'yes' });
                    const stored = await browser.storage.local.get('seen');
                    const tabs = await browser.tabs.query({});
                    return { reply: 'background:' + stored.seen, tabs: tabs.length, active: (await browser.tabs.query({ active: true })).length };
                });
                """,
            "content.js": """
                document.documentElement.setAttribute('data-extension', 'ran');
                browser.runtime.sendMessage({}).then(answer => {
                    document.documentElement.setAttribute('data-reply', answer.reply + ' tabs:' + answer.tabs + ' active:' + answer.active);
                });
                """,
            "popup.html": "<!doctype html><title>Popup</title><p>Popup"
        ])
    }

    static func runsOnPages() async throws {
        let server = try HTMLServer(pages: ["/page": "<title>Page</title><p>Hello"])
        defer { server.stop() }
        let setup = Setup()
        defer { setup.cleanup() }
        let item = try await setup.host.add(files: try messenger())
        #expect(setup.host.context(item.id)?.isLoaded == true && item.name == "Early Test" && item.version == "1.2")
        #expect(setup.host.context(item.id)?.baseURL.scheme == BrowserExtensions.fileScheme, "Folder installs keep WebKit's address")
        #expect(setup.host.context(item.id)?.uniqueIdentifier == item.id.uuidString)
        let tab = try await setup.open(server.url("/page"))
        let view = setup.manager.pages[tab.id]?.view
        try await waitUntil("reply") { await attribute("data-reply", in: view) != nil }
        let reply = await attribute("data-reply", in: view)
        #expect(await attribute("data-extension", in: view) == "ran")
        #expect(reply == "background:yes tabs:1 active:1", "Messaging, storage and Early's tabs")
        let extensionTab = try #require(setup.window.tab(tab.id))
        #expect(setup.host.context(item.id)?.action(for: extensionTab)?.badgeText == "7")

        // The button opens its popup through Early.
        var popups: [WKWebExtension.Action] = []
        setup.host.presentPopup = { popups.append($0); return true }
        setup.host.performAction(item.id, in: extensionTab)
        try await waitUntil("popup") { !popups.isEmpty }
        #expect(popups.first?.popupWebView != nil)

        // Removed: its files and catalog entry go.
        let folder = setup.files.appending(path: item.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await setup.host.remove(item.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path) && setup.host.catalog.extensions.isEmpty)
        #expect(setup.host.context(item.id) == nil)
    }

    /// Its own pages open in tabs (WebKit refuses them in an ordinary view),
    /// and a tab moving between a website and one of them gets a new view.
    static func ownPages() async throws {
        let server = try HTMLServer(pages: ["/page": "<title>Page</title><p>Hello"])
        defer { server.stop() }
        let setup = Setup()
        defer { setup.cleanup() }
        let item = try await setup.host.add(files: try messenger())
        let base = try #require(setup.host.context(item.id)?.baseURL)
        let popup = base.appending(path: "popup.html")
        let tab = try await setup.open(popup)
        let first = try #require(setup.manager.pages[tab.id])
        let title = try await first.view.evaluateJavaScript("document.title") as? String
        #expect(first.failure == nil && first.view.url == popup && title == "Popup")

        setup.manager.load(server.url("/page"), in: tab)
        try await waitUntil("website") {
            setup.manager.pages[tab.id]?.isLoading == false && setup.manager.pages[tab.id]?.view.url?.path == "/page"
        }
        let website = try #require(setup.manager.pages[tab.id])
        #expect(website !== first && website.failure == nil)

        setup.manager.load(popup, in: tab)
        try await waitUntil("its page again") {
            setup.manager.pages[tab.id]?.isLoading == false && setup.manager.pages[tab.id]?.view.url == popup
        }
        #expect(setup.manager.pages[tab.id] !== website && setup.manager.pages[tab.id]?.failure == nil)

        // Following an extension's link out to the web must drop its configuration.
        let own = try #require(setup.manager.pages[tab.id])
        own.view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        var popups: [URL] = []
        setup.manager.onNewWindow = { url, _ in popups.append(url); return nil }
        _ = try await own.view.callAsyncJavaScript("window.open(destination, '_blank'); return true;",
            arguments: ["destination": popup.absoluteString], contentWorld: .page)
        #expect(popups == [popup], "The extension can still open its own pages")

        _ = try await own.view.callAsyncJavaScript("location.href = destination;",
            arguments: ["destination": server.url("/page").absoluteString], contentWorld: .page)
        try await waitUntil("extension link to website") {
            setup.manager.pages[tab.id]?.isLoading == false && setup.manager.pages[tab.id]?.view.url == server.url("/page")
        }
        #expect(setup.manager.pages[tab.id] !== own && setup.manager.pages[tab.id]?.hasExtensionConfiguration == false)
    }

    static func protectedPages() async throws {
        let server = try HTMLServer(pages: ["/page": "<title>Website</title><p>Ordinary web content"])
        defer { server.stop() }
        let setup = Setup()
        defer { setup.cleanup() }
        let folder = try extensionFolder([
            "manifest.json": """
                {"manifest_version": 3, "name": "Protected pages", "version": "1.0",
                 "web_accessible_resources": [{"resources": ["public.txt"], "matches": ["http://127.0.0.1/*"]}]}
                """,
            "private.html": "<!doctype html><title>Protected extension page</title>",
            "public.txt": "Public resource"
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try await setup.host.add(files: folder)
        let base = try #require(setup.host.context(item.id)?.baseURL)
        let target = base.appending(path: "private.html")
        let tab = try await setup.open(server.url("/page"))
        let page = try #require(setup.manager.pages[tab.id])

        // WebKit still allows resources the extension deliberately exposes.
        let publicText = try await page.view.callAsyncJavaScript("return await (await fetch(url)).text();",
            arguments: ["url": base.appending(path: "public.txt").absoluteString], contentWorld: .page) as? String
        #expect(publicText == "Public resource")

        // Browser shortcuts must not turn a page's link into a trusted load.
        var opened: [URL] = []
        setup.manager.onOpenBackgroundLink = { opened.append($0) }
        setup.manager.onOpenWindowLink = { opened.append($0) }
        #expect(!setup.manager.openContextLink(target, in: page.view, background: true))
        #expect(!setup.manager.openContextLinkInWindow(target, in: page.view))
        #expect(opened.isEmpty)

        // Exercise the actual popup route, with an ordinary website popup as a
        // control so popup blocking cannot hide a missing origin check.
        page.view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        var popups: [URL] = []
        setup.manager.onNewWindow = { url, _ in popups.append(url); return nil }
        _ = try await page.view.callAsyncJavaScript("window.open(destination, '_blank'); return true;",
            arguments: ["destination": server.url("/page").absoluteString], contentWorld: .page)
        #expect(popups == [server.url("/page")])
        _ = try await page.view.callAsyncJavaScript("window.open(destination, '_blank'); return true;",
            arguments: ["destination": target.absoluteString], contentWorld: .page)
        #expect(popups == [server.url("/page")], "A protected page must not become a new tab")

        _ = try await page.view.callAsyncJavaScript("location.href = destination;",
            arguments: ["destination": target.absoluteString], contentWorld: .page)
        try await waitUntil("protected navigation rejected") {
            setup.manager.pages[tab.id] !== page || page.navigationNotice != nil
        }
        #expect(setup.manager.pages[tab.id] === page, "A website must never get an extension's privileged view")
        #expect(page.view.url == server.url("/page") && page.requestedURL == server.url("/page"))
        #expect(!page.hasExtensionConfiguration)
    }

    static func siteAccess() async throws {
        let server = try HTMLServer(pages: ["/page": "<title>Page</title><p>Hello"])
        defer { server.stop() }
        let setup = Setup()
        defer { setup.cleanup() }
        let item = try await setup.host.add(files: try messenger())
        // Running everywhere first, as an extension is when someone changes
        // its access in Settings. (Changing permissions while it's still
        // starting up intermittently trips WebKit on macOS 26.)
        let tab = try await setup.open(server.url("/page"))
        try await waitUntil("runs on every site") {
            await attribute("data-extension", in: setup.manager.pages[tab.id]?.view) == "ran"
        }
        // As Settings does: access changes without restarting the extension.
        setup.host.catalog.change(item.id) { $0.siteAccess = .whenClicked }
        setup.host.refreshAccess(item.id)
        setup.manager.reload(tab.id)
        try await waitUntil("reloaded") { setup.manager.pages[tab.id]?.isLoading == false }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await attribute("data-extension", in: setup.manager.pages[tab.id]?.view) == nil, "Nothing runs until allowed")

        await setup.host.setAllowed(true, site: "127.0.0.1", for: item.id)
        #expect(setup.host.catalog.installed(item.id)?.allowedSites == ["127.0.0.1"])
        setup.manager.reload(tab.id)
        try await waitUntil("allowed") { setup.manager.pages[tab.id]?.isLoading == false }
        try await waitUntil("runs on the allowed site") {
            await attribute("data-extension", in: setup.manager.pages[tab.id]?.view) == "ran"
        }

        await setup.host.setAllowed(false, site: "127.0.0.1", for: item.id)
        setup.manager.reload(tab.id)
        try await waitUntil("reloaded again") { setup.manager.pages[tab.id]?.isLoading == false }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await attribute("data-extension", in: setup.manager.pages[tab.id]?.view) == nil, "Taking a site back stops it there")
    }

    static func blocker(_ name: String, path: String) throws -> URL {
        try extensionFolder([
            "manifest.json": """
                {"manifest_version": 3, "name": "\(name)", "version": "1.0", "description": "Test blocker",
                 "permissions": ["declarativeNetRequest"], "host_permissions": ["<all_urls>"],
                 "declarative_net_request": {"rule_resources": [{"id": "rules", "enabled": true, "path": "rules.json"}]}}
                """,
            "rules.json": """
                [{"id": 1, "priority": 1, "action": {"type": "block"},
                  "condition": {"urlFilter": "\(path)", "resourceTypes": ["script"]}}]
                """
        ])
    }

    /// Whether a script at `path` loads in the page, or is blocked.
    static func scriptLoads(_ path: String, in view: WKWebView?) async throws -> Bool? {
        let result = try await view?.callAsyncJavaScript("""
            return await new Promise(resolve => {
                const script = document.createElement('script');
                script.src = path + '?' + Math.random();
                script.onload = () => resolve(true);
                script.onerror = () => resolve(false);
                document.head.appendChild(script);
            });
            """, arguments: ["path": path], contentWorld: .page)
        return result as? Bool
    }

    static func blockersStayOn() async throws {
        let server = try HTMLServer(pages: ["/page": "<title>Page</title>", "/a.js": "1", "/b.js": "1"])
        defer { server.stop() }
        let setup = Setup()
        defer { setup.cleanup() }
        let first = try await setup.host.add(files: try blocker("Blocks A", path: "/a.js"))
        _ = try await setup.host.add(files: try blocker("Blocks B", path: "/b.js"))
        let tab = try await setup.open(server.url("/page"))
        var view = setup.manager.pages[tab.id]?.view
        try await waitUntil("both block") {
            let a = try await scriptLoads("/a.js", in: view), b = try await scriptLoads("/b.js", in: view)
            return a == false && b == false
        }
        setup.host.catalog.change(first.id) { $0.isEnabled = false }
        setup.host.unload(first.id)
        setup.manager.reload(tab.id)
        try await waitUntil("reloaded") { setup.manager.pages[tab.id]?.isLoading == false }
        view = setup.manager.pages[tab.id]?.view
        try await waitUntil("A loads, B still blocked") {
            let a = try await scriptLoads("/a.js", in: view), b = try await scriptLoads("/b.js", in: view)
            return a == true && b == false
        }
    }

    static func privateWindows() async throws {
        let catalog = ExtensionCatalog(fileURL: nil)
        let normal = Setup(catalog: catalog)
        defer { normal.cleanup() }
        let allowed = try await normal.host.add(files: try messenger(name: "Allowed"))
        let other = try await normal.host.add(files: try messenger(name: "Not allowed"))
        catalog.change(allowed.id) { $0.allowsPrivateWindows = true }
        let privateSetup = Setup(isPrivate: true, catalog: catalog)
        defer { privateSetup.cleanup() }
        // The private host reads the same files.
        let privateHost = ExtensionHost(catalog: catalog, filesDirectory: normal.files, websiteDataStore: .nonPersistent(),
                                        storageIdentifier: nil, isPrivate: true)
        defer { privateHost.unloadAll() }
        await privateHost.loadEnabled()
        #expect(privateHost.context(allowed.id) != nil && privateHost.context(other.id) == nil)
        #expect(privateHost.context(allowed.id)?.hasAccessToPrivateData == true)
        #expect(normal.host.context(other.id)?.hasAccessToPrivateData == false)
    }
}

/// A loopback server for a few fixed pages, or answers chosen per request.
final class HTMLServer: @unchecked Sendable {
    struct Response: Sendable {
        var status = "200 OK"
        var headers: [String: String] = [:]
        var body: String
        var delay: TimeInterval = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.early.tests.html")
    private let respond: @Sendable (_ path: String, _ query: String) -> Response?
    private(set) var port: UInt16 = 0

    convenience init(pages: [String: String]) throws {
        try self.init { path, _ in pages[path].map { Response(body: $0) } }
    }

    /// The query arrives as sent (percent-encoded).
    init(respond: @escaping @Sendable (_ path: String, _ query: String) -> Response?) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [respond] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
            let path = parts.first ?? "/"
            let answer = respond(path, parts.count > 1 ? parts[1] : "") ?? Response(status: "404 Not Found", body: "missing")
            var headers = answer.headers
            headers["Content-Type"] = headers["Content-Type"] ?? (path.hasSuffix(".js") ? "text/javascript" : "text/html")
            headers["Content-Length"] = "\(answer.body.utf8.count)"
            headers["Connection"] = "close"
            let lines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            let response = "HTTP/1.1 \(answer.status)\r\n\(lines)\r\n\r\n\(answer.body)"
            let payload = Data(response.utf8)
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay) {
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
