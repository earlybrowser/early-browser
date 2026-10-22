// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Menu construction, validation and dispatch with unshown views. Trusted
/// right-clicks themselves are covered by the native UI suite.
@Suite(.serialized) @MainActor
struct PageContextMenuTests {
    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }

    private func view() -> BrowserWebView {
        _ = NSApplication.shared
        return BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @Test func plainPageMenuOffersOnlyWorkingPageCommands() {
        let menu = view().makeContextMenu(for: .init())
        #expect(titles(menu) == ["Back", "Forward", "Reload", "—", "Save Page As…", "Print…"])
        // A fresh view has no history or document yet.
        #expect(menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)
            == ["Back", "Forward", "Save Page As…", "Print…"])
        #expect(!menu.allowsContextMenuPlugIns && !menu.autoenablesItems)
    }

    @Test func imageSelectionAndLinkSectionsContainOnlySupportedActions() throws {
        let web = URL(string: "https://example.com/photo.png")!
        let data = URL(string: "data:image/png;base64,AAAA")!
        let link = URL(string: "https://example.com/page")!
        let view = view()
        #expect(titles(view.makeContextMenu(for: .init(image: web)))
            == ["Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address"])
        #expect(titles(view.makeContextMenu(for: .init(image: data))) == ["Save Image As…", "Copy Image"])
        let long = String(repeating: "searchable words ", count: 8)
        let selection = view.makeContextMenu(for: .init(selection: long))
        let search = try #require(selection.items.first?.title)
        #expect(search.hasPrefix("Search with Google for “") && search.hasSuffix("…”") && search.count < 60)
        #expect(titles(selection).dropFirst() == ["Copy", "Look Up “\(BrowserWebView.menuExcerpt(long))”", "Share"])
        #expect(titles(view.makeContextMenu(for: .init(link: link, image: web)))
            == ["Open Link in New Tab", "Open Link in New Window", "Download Linked File", "Copy Link", "Share", "—",
                "Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address"])
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

        manager.showContextMenu(link: "javascript:alert(1)", image: nil, selection: "   ", in: view)
        manager.showContextMenu(link: "file:///etc/hosts", image: "blob:https://example.com/id", selection: nil, in: view)
        manager.showContextMenu(link: nil, image: "ftp://example.com/a.png", selection: " Early ", in: view)
        #expect(shown.count == 3)
        #expect(shown[0].first == "Back", "Unsupported links and blank selections fall back to the page menu")
        #expect(shown[1] == ["Save Image As…", "Copy Image"], "A web page cannot offer a local file link")
        #expect(shown[2] == ["Search with Google for “Early”", "Copy", "Look Up “Early”", "Share"])
        #expect(!window.isVisible)
    }
}
