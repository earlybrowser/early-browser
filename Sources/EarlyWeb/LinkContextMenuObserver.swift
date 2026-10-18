// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Only trusted link context-menu events enter the native menu bridge. The
/// isolated world is not exposed to page scripts, and every URL is validated
/// again by the owner before showing a menu or dispatching a navigation.
@MainActor
final class LinkContextMenuObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyLinkContextMenu"
    static let world = WKContentWorld.world(name: "Early.LinkContextMenu")
    static let script = """
    (() => {
        window.addEventListener('contextmenu', event => {
            if (!event.isTrusted || event.defaultPrevented) return;
            const link = event.composedPath().find(node =>
                node instanceof Element && node.matches('a[href],area[href]'));
            if (!link) return;
            let href;
            try { href = new URL(link.getAttribute('href'), document.baseURI).href; }
            catch { return; }
            if (href.length > 16384) return;
            event.preventDefault();
            window.webkit.messageHandlers.earlyLinkContextMenu.postMessage({href});
        });
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world,
              let view = message.webView as? BrowserWebView,
              let body = message.body as? [String: Any], let href = body["href"] as? String,
              href.utf8.count <= 16384 else { return }
        owner?.showLinkContextMenu(href: href, in: view)
    }
}
