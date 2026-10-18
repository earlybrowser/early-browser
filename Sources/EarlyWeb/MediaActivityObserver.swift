// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Isolated, event-driven HTML audio/video activity, including child frames.
/// No polling, audio capture, or page-world API overrides.
@MainActor
final class MediaActivityObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyMediaActivity"
    static let script = """
    (() => {
        const token = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
            : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        let last = null, queued = false;
        const elements = new Set();
        const scan = root => {
            if (root instanceof HTMLMediaElement) elements.add(root);
            if (root.querySelectorAll) root.querySelectorAll('audio,video').forEach(el => elements.add(el));
        };
        const send = playing => {
            if (playing === last) return;
            last = playing;
            window.webkit.messageHandlers.earlyMediaActivity.postMessage({token, playing});
        };
        const update = () => {
            if (queued) return;
            queued = true;
            queueMicrotask(() => {
                queued = false;
                for (const el of elements) if (!el.isConnected) elements.delete(el);
                send(Array.from(elements).some(el => !el.paused && !el.ended && !el.muted && el.volume > 0));
            });
        };
        for (const event of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
            document.addEventListener(event, e => {
                if (e.target instanceof HTMLMediaElement) { elements.add(e.target); update(); }
            }, true);
        }
        new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) scan(node);
            update();
        }).observe(document, {subtree: true, childList: true});
        document.addEventListener('DOMContentLoaded', () => { scan(document); update(); }, {once: true});
        window.addEventListener('pagehide', () => send(false));
        window.addEventListener('pageshow', update);
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let body = message.body as? [String: Any],
              let token = body["token"] as? String, token.count <= 64,
              let playing = body["playing"] as? Bool else { return }
        owner?.updateMediaActivity(in: view, token: token, playing: playing)
    }
}
