// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Menu construction, validation and dispatch with unshown views. Native
/// right-click events go to an unshown window; the UI suite covers real ones.
@Suite(.serialized) @MainActor
struct PageContextMenuTests {
    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }

    private func view() -> BrowserWebView {
        _ = NSApplication.shared
        return BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @Test func plainPageMenuOffersOnlyWorkingPageCommands() {
        let menu = view().makeContextMenu(for: .init())
        #expect(titles(menu) == ["Back", "Forward", "Reload", "—", "Save Page As…", "Print…", "—", "View Page Source"])
        // A fresh view has no history or document yet.
        #expect(menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)
            == ["Back", "Forward", "Save Page As…", "Print…", "View Page Source"])
        #expect(!menu.allowsContextMenuPlugIns && !menu.autoenablesItems)
    }

    @Test func imageSelectionAndLinkSectionsContainOnlySupportedActions() throws {
        let web = URL(string: "https://example.com/photo.png")!
        let data = URL(string: "data:image/png;base64,AAAA")!
        let link = URL(string: "https://example.com/page")!
        let view = view()
        let source = ["—", "View Page Source"]
        #expect(titles(view.makeContextMenu(for: .init(image: web)))
            == ["Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address"] + source)
        #expect(titles(view.makeContextMenu(for: .init(image: data))) == ["Save Image As…", "Copy Image"] + source)
        let long = String(repeating: "searchable words ", count: 8)
        let selection = view.makeContextMenu(for: .init(selection: long))
        let search = try #require(selection.items.first?.title)
        #expect(search.hasPrefix("Search with Google for “") && search.hasSuffix("…”") && search.count < 60)
        #expect(Array(titles(selection).dropFirst()) == ["Copy", "Look Up “\(BrowserWebView.menuExcerpt(long))”", "Share"] + source)
        #expect(titles(view.makeContextMenu(for: .init(link: link, image: web)))
            == ["Open Link in New Tab", "Open Link in New Window", "Download Linked File", "Copy Link", "Share", "—",
                "Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address"] + source)
    }

    @Test func menuItemsDispatchTheirExactTargets() {
        let web = URL(string: "https://example.com/photo.png?size=large")!
        let view = view()
        var actions: [BrowserWebView.ContextAction] = [], copied: [URL] = []
        view.onContextAction = { actions.append($0) }
        view.copyLink = { copied.append($0) } // Do not overwrite the user's clipboard.
        let image = view.makeContextMenu(for: .init(image: web))
        for index in image.items.indices { image.performActionForItem(at: index) }
        let page = view.makeContextMenu(for: .init())
        page.performActionForItem(at: 2)
        view.makeContextMenu(for: .init(selection: "early browser")).performActionForItem(at: 0)
        #expect(actions == [.openImageInNewTab(web), .saveImage(web), .copyImage(web), .reload, .searchSelection("early browser")])
        #expect(copied == [web])
    }

    @Test func rightClickOnAWordShowsTheTextMenuAndBlankSpaceThePageMenu() async throws {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["http", "https"]), observesMemoryPressure: false)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Source", currentURL: URL(string: "https://example.com/source")!)
        let view = try #require(manager.prepare(tab).view as? BrowserWebView)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { manager.discardAll(); window.close() }
        var shown: [[String]] = []
        view.presentMenu = { menu, _ in shown.append(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }) }
        view.loadHTMLString("""
            <body style="margin:0;font:20px -apple-system"><p id="text" style="margin:0;padding:8px">Plain page area</p>
            <div style="height:300px"></div></body>
            """, baseURL: URL(string: "https://example.com/source"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isLoading || view.url == nil {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        // WebKit's own menu would start real menu tracking in this test, so the
        // page uses Early's menu here; filling WebKit's is tested on its own.
        view.inspectsElements = false
        _ = try await view.callAsyncJavaScript("window.__earlyOwnMenu = true", contentWorld: PageContextMenuObserver.world)
        func rightClick(atTop y: CGFloat) async throws -> [String]? {
            let before = shown.count
            let location = view.convert(CGPoint(x: 30, y: y), to: nil)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                type == .rightMouseDown ? view.rightMouseDown(with: event) : view.rightMouseUp(with: event)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while shown.count == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            return shown.count > before ? shown.last : nil
        }
        // WebKit's view is flipped: y is measured from the top.
        #expect(try await rightClick(atTop: 20)?.first?.hasPrefix("Search with Google for") == true, "\(shown)")
        #expect(try await rightClick(atTop: 200) == ["Back", "Forward", "Reload", "—", "Save Page As…", "Print…", "—", "View Page Source"],
                "\(shown)")
        #expect(!window.isVisible)
    }

    @Test func managerValidatesTargetsBeforeShowingAMenu() throws {
        _ = NSApplication.shared
        let profile = UUID()
        // The app's real schemes: local files are valid addresses, yet a web
        // page still cannot offer one.
        let manager = WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["http", "https", "file"]), observesMemoryPressure: false)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Source", currentURL: URL(string: "https://example.com/source")!)
        let view = try #require(manager.prepare(tab).view as? BrowserWebView)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { manager.discardAll(); window.close() }
        var shown: [[String]] = []
        view.presentMenu = { menu, _ in shown.append(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }) }
        // Validation is the same whichever menu shows the items; check it on Early's own.
        view.inspectsElements = false

        manager.showContextMenu(link: "javascript:alert(1)", image: nil, selection: "   ", in: view)
        manager.showContextMenu(link: "file:///etc/hosts", image: "blob:https://example.com/id", selection: nil, in: view)
        manager.showContextMenu(link: nil, image: "ftp://example.com/a.png", selection: " Early ", in: view)
        #expect(shown.count == 3)
        #expect(shown[0].first == "Back", "Unsupported links and blank selections fall back to the page menu")
        #expect(shown[1] == ["Save Image As…", "Copy Image", "—", "View Page Source"], "A web page cannot offer a local file link")
        #expect(shown[2] == ["Search with Google for “Early”", "Copy", "Look Up “Early”", "Share", "—", "View Page Source"])
        #expect(!window.isVisible)
    }
}
