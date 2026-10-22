// SPDX-License-Identifier: MPL-2.0

import WebKit

/// The address shown while the pointer is over a link.
public struct LinkHover: Equatable, Sendable {
    public let url: URL
    /// The pointer is over the preview's usual bottom-leading spot, so it
    /// moves to the trailing corner instead of covering what is being read.
    public let avoidsLeadingCorner: Bool
}

/// Reports the hovered link's address from an isolated world. It only reads
/// trusted pointer events; it never handles clicks or changes the page.
@MainActor
final class LinkHoverObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyLinkHover"
    static let world = WKContentWorld.world(name: "Early.LinkHover")
    static let script = """
    (() => {
        const limit = 2048;
        let current = null;
        const post = message => {
            try { window.webkit.messageHandlers.earlyLinkHover.postMessage(message); } catch (_) {}
        };
        const address = link => {
            const raw = link.getAttribute('href');
            if (!raw) return null;
            try {
                const href = new URL(raw, document.baseURI).href;
                return href.length <= limit ? href : null;
            } catch (_) { return null; }
        };
        document.addEventListener('mouseover', event => {
            if (!event.isTrusted) return;
            const link = event.composedPath().find(node => node instanceof Element && node.matches('a[href], area[href]'));
            const href = link ? address(link) : null;
            if (href === current) return;
            current = href;
            if (!href) { post({}); return; }
            const corner = window === window.top && event.clientY > innerHeight - 48 && event.clientX < innerWidth * 0.6;
            post({ href, corner });
        }, true);
        const clear = () => {
            if (current === null) return;
            current = null;
            post({});
        };
        document.addEventListener('mouseout', event => { if (!event.relatedTarget) clear(); }, true);
        document.addEventListener('keydown', clear, true);
        window.addEventListener('scroll', clear, true);
        window.addEventListener('blur', clear);
        window.addEventListener('pagehide', clear);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world, let view = message.webView,
              let body = message.body as? [String: Any] else { return }
        owner?.updateLinkHover(in: view, href: body["href"] as? String, avoidsCorner: body["corner"] as? Bool ?? false)
    }
}

@MainActor
extension WebViewManager {
    /// Only addresses Early itself could open (or mail and phone links) are
    /// shown; `javascript:` and other schemes show nothing.
    func updateLinkHover(in view: WKWebView, href: String?, avoidsCorner: Bool) {
        guard let id = tabID(for: view), let page = pages[id] else { return }
        var hover: LinkHover?
        if let href, href.utf8.count <= 2048, let url = URL(string: href) {
            let scheme = url.scheme?.lowercased() ?? ""
            if ["mailto", "tel"].contains(scheme) || (try? input.validate(url)) != nil {
                hover = LinkHover(url: url, avoidsLeadingCorner: avoidsCorner)
            }
        }
        if page.hoveredLink != hover { page.hoveredLink = hover }
    }
}
