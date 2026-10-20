// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Protect documents with user edits without collecting field values. The
/// isolated bridge only sends a document token and a dirty/removed flag.
@MainActor
final class PageInteractionObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyPageInteraction"
    static let script = """
    (() => {
        const token = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
            : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        let dirty = false;
        const send = removed => {
            try { window.webkit.messageHandlers.earlyPageInteraction.postMessage({token, removed}); } catch (_) {}
        };
        const edited = event => {
            if (dirty || !event.isTrusted) return;
            const target = event.composedPath()[0];
            if (!(target instanceof Element) || !target.matches('input,textarea,select,[contenteditable]')
                && !target.isContentEditable) return;
            dirty = true;
            send(false);
        };
        document.addEventListener('input', edited, true);
        document.addEventListener('change', edited, true);
        window.addEventListener('pagehide', () => { if (dirty) send(true); });
        window.addEventListener('pageshow', () => { if (dirty) send(false); });
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let body = message.body as? [String: Any],
              let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 128,
              let removed = body["removed"] as? Bool else { return }
        owner?.updatePageInteraction(in: view, token: token, removed: removed)
    }
}

