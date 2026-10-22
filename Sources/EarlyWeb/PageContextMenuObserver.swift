// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Only trusted right-clicks enter the native menu bridge. The isolated world
/// is not exposed to page scripts, and every link/image address is validated
/// again by the owner before showing a menu or dispatching an action. Pages
/// that show their own menu, editable fields and media keep their behavior.
@MainActor
final class PageContextMenuObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyContextMenu"
    static let world = WKContentWorld.world(name: "Early.PageContextMenu")
    static let script = """
    (() => {
        const limit = 16384;
        const absolute = value => {
            try {
                const href = new URL(value, document.baseURI).href;
                return href.length <= limit ? href : null;
            } catch { return null; }
        };
        const matches = (node, selector) => node instanceof Element && node.matches(selector);
        window.addEventListener('contextmenu', event => {
            if (!event.isTrusted || event.defaultPrevented) return;
            const path = event.composedPath();
            if (path.some(node => node instanceof Element && node.isContentEditable)) return;
            if (path.some(node => matches(node, 'input, textarea, select, video, audio'))) return;
            const message = {};
            const link = path.find(node => matches(node, 'a[href], area[href]'));
            if (link) {
                const href = absolute(link.getAttribute('href'));
                if (href) message.link = href;
            }
            const image = path.find(node => node instanceof HTMLImageElement);
            if (image) {
                const src = image.currentSrc || image.src;
                if (src && src.length <= limit) message.image = src;
            }
            const selection = window.getSelection();
            if (selection && !selection.isCollapsed) {
                const x = event.clientX, y = event.clientY;
                for (let index = 0; index < selection.rangeCount; index++) {
                    const rects = Array.from(selection.getRangeAt(index).getClientRects());
                    if (rects.some(r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom)) {
                        message.selection = selection.toString().slice(0, 4096);
                        break;
                    }
                }
            }
            event.preventDefault();
            window.webkit.messageHandlers.earlyContextMenu.postMessage(message);
        });
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world,
              let view = message.webView as? BrowserWebView,
              let body = message.body as? [String: Any] else { return }
        owner?.showContextMenu(link: body["link"] as? String, image: body["image"] as? String,
                               selection: body["selection"] as? String, in: view)
    }
}
