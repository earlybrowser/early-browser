// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Watches only the main document's icon declarations, in an isolated world.
/// Notifications ask native code to read the current document, so a queued
/// message from a departed page cannot supply stale artwork.
@MainActor
final class FaviconObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyFavicon"
    static let world = WKContentWorld.world(name: "Early.Favicon")

    private static let iconLinks = """
        Array.from(document.head?.querySelectorAll('link[rel~="icon" i]') || []).slice(0, 64)
        """

    static let discoveryScript = """
        (() => ({
            appearance: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
            links: \(iconLinks)
                .filter(link => !link.media || (link.media.length <= 1024 && matchMedia(link.media).matches))
                .reverse().map(link => link.href).filter(href => href && href.length <= 4096).slice(0, 8)
        }))()
        """

    static let script = """
        (() => {
            let head = null, timer = null, previous = null, active = false;
            const queries = new Map();
            const report = () => {
                timer = null;
                if (!active) return;
                const media = new Set(['(prefers-color-scheme: dark)']);
                for (const link of \(iconLinks)) {
                    if (link.media && link.media.length <= 1024) media.add(link.media);
                }
                for (const [text, query] of queries) {
                    if (!media.has(text)) { query.removeEventListener('change', schedule); queries.delete(text); }
                }
                for (const text of media) {
                    if (!queries.has(text)) {
                        const query = matchMedia(text);
                        query.addEventListener('change', schedule);
                        queries.set(text, query);
                    }
                }
                const value = JSON.stringify(\(discoveryScript));
                if (value === previous) return;
                previous = value;
                try { window.webkit.messageHandlers.earlyFavicon.postMessage('changed'); } catch (_) {}
            };
            const schedule = () => {
                if (active && timer === null) timer = setTimeout(report, 100);
            };
            const changes = new MutationObserver(schedule);
            const connectHead = () => {
                if (head !== document.head) {
                    changes.disconnect();
                    head = document.head;
                    if (head) changes.observe(head, {
                        childList: true, subtree: true, attributes: true,
                        attributeFilter: ['href', 'rel', 'media', 'type', 'sizes']
                    });
                }
                schedule();
            };
            const roots = new MutationObserver(connectHead);
            const start = () => {
                active = true;
                if (document.documentElement) roots.observe(document.documentElement, { childList: true });
                connectHead();
                schedule();
            };
            window.addEventListener('pagehide', () => {
                active = false;
                if (timer !== null) clearTimeout(timer);
                timer = null; previous = null; head = null;
                changes.disconnect(); roots.disconnect();
                for (const query of queries.values()) query.removeEventListener('change', schedule);
                queries.clear();
            });
            window.addEventListener('pageshow', start);
            start();
        })();
        """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world, message.frameInfo.isMainFrame,
              message.body as? String == "changed", let view = message.webView else { return }
        owner?.refreshFavicon(in: view)
    }
}

extension WebViewManager {
    func refreshFavicon(in view: WKWebView) {
        guard let id = tabID(for: view), let page = pages[id], !page.awaitsNavigationCommit,
              let url = view.url, FaviconStore.origin(url) != nil else { return }
        let generation = page.navigationGeneration
        let refresh = UUID()
        page.faviconRefresh = refresh
        view.evaluateJavaScript(FaviconObserver.discoveryScript, in: nil, in: FaviconObserver.world) { [weak self, weak page] result in
            guard let self, let page, self.pages[id] === page,
                  page.navigationGeneration == generation, page.faviconRefresh == refresh, page.view.url == url else { return }
            page.faviconRefresh = nil
            guard let value = (try? result.get()) as? [String: Any],
                  let appearance = (value["appearance"] as? String).flatMap(FaviconStore.Appearance.init(rawValue:)),
                  let links = value["links"] as? [String] else {
                self.favicons.request(url)
                return
            }
            self.favicons.request(url, discovered: links, appearance: appearance)
        }
    }
}
