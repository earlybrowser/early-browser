import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct BrowserWebViewTests {
    @Test func ownedLinkMenuContainsExactlySupportedLeafActions() {
        _ = NSApplication.shared
        let view = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let url = URL(string: "https://example.com/page?query=one#section")!
        let menu = view.makeLinkMenu(for: url)

        #expect(menu.items.map(\.title) == ["Open Link in New Tab", "Open Link in New Window", "Copy Link", "Share"])
        #expect(!menu.autoenablesItems)
        #expect(!menu.allowsContextMenuPlugIns)
        if #available(macOS 15.2, *) {
            #expect(!menu.automaticallyInsertsWritingToolsItems)
        }
        for item in menu.items {
            #expect(!item.isSeparatorItem)
            #expect(item.submenu == nil)
            #expect(item.isEnabled)
            #expect(item.target === view)
            #expect(item.representedObject as? URL == url)
        }
    }

    @Test func nativeMenuDispatchesExactURLsWithoutSharingRequestState() {
        _ = NSApplication.shared
        let view = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let first = URL(string: "https://example.com/first?query=one#section")!
        let second = URL(string: "https://example.com/second?query=two#other")!
        var opened: [URL] = [], background: [URL] = [], copied: [URL] = [], shared: [URL] = []
        view.onOpenWindowLink = { opened.append($0) }
        view.onOpenBackgroundLink = { background.append($0) }
        view.copyLink = { copied.append($0) } // Do not overwrite the user's clipboard.
        view.shareLink = { shared.append($0) } // Never open an external share service in tests.
        let firstMenu = view.makeLinkMenu(for: first)
        let secondMenu = view.makeLinkMenu(for: second)

        firstMenu.performActionForItem(at: 0)
        secondMenu.performActionForItem(at: 1)
        firstMenu.performActionForItem(at: 2)
        secondMenu.performActionForItem(at: 3)

        #expect(opened == [second])
        #expect(background == [first])
        #expect(copied == [first])
        #expect(shared == [second])
    }

    @Test func bridgeAcceptsOnlyValidatedURLsFromOwnedViews() {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        let source = URL(string: "https://example.com/source")!
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Source", currentURL: source)
        let page = manager.prepare(tab)
        let target = URL(string: "https://example.com/target?query=one#section")!
        var background: [URL] = []
        manager.onOpenBackgroundLink = { background.append($0) }
        var windows: [URL] = []
        manager.onOpenWindowLink = { windows.append($0) }
        #expect(manager.openContextLinkInWindow(target, in: page.view))
        #expect(windows == [target])

        #expect(manager.contextLinkURL(href: target.absoluteString, in: page.view) == target)
        #expect(manager.openContextLink(target, in: page.view, background: true))
        #expect(background == [target])
        #expect(page.requestedURL == source)
        #expect(page.view.url == nil)
        #expect(manager.liveViewCount == 1)

        for href in ["javascript:alert(1)", "file:///tmp/example.html",
                     "https://user:password@example.com/", "https://example.com:65536/",
                     "https://example.com/" + String(repeating: "x", count: 16385)] {
            #expect(manager.contextLinkURL(href: href, in: page.view) == nil)
        }
        #expect(!manager.openContextLink(URL(string: "javascript:alert(1)")!, in: page.view, background: true))
        let unrelated = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(manager.contextLinkURL(href: target.absoluteString, in: unrelated) == nil)
        #expect(!manager.openContextLink(target, in: unrelated, background: true))
        #expect(!manager.openContextLinkInWindow(target, in: unrelated))
        #expect(!manager.openContextLinkInWindow(URL(string: "file:///tmp/example.html")!, in: page.view))

        manager.discardAll()
        #expect(manager.contextLinkURL(href: target.absoluteString, in: page.view) == nil)
        #expect(!manager.openContextLink(target, in: page.view, background: true))
        #expect(background == [target])
        #expect(!manager.openContextLinkInWindow(target, in: page.view))
        #expect(windows == [target])
    }

    @Test func isolatedBridgeIsInstalledOnceAlongsideMediaAndCallbacksAreReleased() throws {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Source",
                             currentURL: URL(string: "https://example.com/source")!)
        let page = manager.prepare(tab)
        let view = try #require(page.view as? BrowserWebView)
        let scripts = view.configuration.userContentController.userScripts
        let bridge = try #require(scripts.first { $0.source == LinkContextMenuObserver.script })

        #expect(scripts.filter { $0.source == LinkContextMenuObserver.script }.count == 1)
        #expect(bridge.injectionTime == .atDocumentStart)
        #expect(!bridge.isForMainFrameOnly)
        #expect(LinkContextMenuObserver.world.name == "Early.LinkContextMenu")
        #expect(scripts.contains { $0.source == MediaActivityObserver.script })
        #expect(manager.prepare(tab) === page)
        #expect(view.onOpenWindowLink != nil)
        #expect(view.onOpenBackgroundLink != nil)

        manager.discardAll()
        #expect(view.onOpenWindowLink == nil)
        #expect(view.onOpenBackgroundLink == nil)
        #expect(manager.liveViewCount == 0)
    }
}
