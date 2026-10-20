// SPDX-License-Identifier: MPL-2.0

import WebKit

/// Isolated HTML media activity and temporary muting, including child frames.
/// Uses public DOM APIs, never changes volume or pauses playback, and restores
/// each element's previous mute setting. Web Audio-only output is not covered.
@MainActor
final class MediaActivityObserver: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WebViewManager?
    static let name = "earlyMediaActivity"
    static let script = """
    (() => {
        const token = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
            : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        let last = null, queued = false, hidden = false, muted = false, revision = -1;
        const elements = new Set();
        const observed = new WeakSet(), previousMute = new Map();
        const enforceMute = el => {
            if (!muted) return;
            if (!previousMute.has(el)) previousMute.set(el, el.muted);
            if (!el.muted) el.muted = true;
        };
        const restoreMute = el => {
            if (!previousMute.has(el)) return;
            const previous = previousMute.get(el);
            previousMute.delete(el);
            el.muted = previous;
        };
        const applyState = state => {
            if (!state || state.revision < revision) return;
            revision = state.revision;
            muted = state.muted;
            for (const el of elements) {
                if (muted) enforceMute(el);
                else restoreMute(el);
            }
            update();
        };
        const send = (playing, removed = false) => {
            if (!removed && playing === last) return;
            last = playing;
            window.webkit.messageHandlers.earlyMediaActivity.postMessage({token, playing, removed})
                .then(state => { if (!hidden) applyState(state); }).catch(() => {});
        };
        const update = () => {
            if (queued || hidden) return;
            queued = true;
            queueMicrotask(() => {
                queued = false;
                if (hidden) return;
                for (const el of elements) {
                    if (!el.isConnected && (el.paused || el.ended)) {
                        restoreMute(el);
                        elements.delete(el);
                    } else enforceMute(el);
                }
                // Keep playback activity independent of Early's mute so the
                // speaker does not blink out and back in when unmuting.
                send(Array.from(elements).some(el => !el.paused && !el.ended && el.volume > 0
                    && (muted ? previousMute.get(el) === false : !el.muted)));
            });
        };
        const events = ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'];
        const track = el => {
            elements.add(el);
            if (!observed.has(el)) {
                observed.add(el);
                for (const event of events) el.addEventListener(event, () => {
                    if (!el.isConnected && (el.paused || el.ended)) {
                        restoreMute(el);
                        elements.delete(el);
                    } else {
                        elements.add(el);
                        enforceMute(el);
                    }
                    update();
                });
            }
            enforceMute(el);
        };
        const scan = root => {
            if (root instanceof HTMLMediaElement) track(root);
            if (root.querySelectorAll) root.querySelectorAll('audio,video').forEach(track);
        };
        for (const event of events) document.addEventListener(event, e => {
            if (e.target instanceof HTMLMediaElement) { track(e.target); update(); }
        }, true);
        new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) scan(node);
            update();
        }).observe(document, {subtree: true, childList: true});
        document.addEventListener('DOMContentLoaded', () => { scan(document); update(); }, {once: true});
        window.addEventListener('pagehide', () => { hidden = true; send(false, true); });
        window.addEventListener('pageshow', () => { hidden = false; last = null; scan(document); update(); });
        // Only the native owner in the isolated world can set tab mute state.
        globalThis.__earlyMediaControl = {applyState};
        scan(document);
        update();
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.world === WKContentWorld.defaultClient,
              let view = message.webView, let body = message.body as? [String: Any],
              let token = body["token"] as? String, token.count <= 64,
              let playing = body["playing"] as? Bool,
              let state = owner?.updateMediaActivity(in: view, token: token, playing: playing,
                  frame: message.frameInfo, removed: body["removed"] as? Bool ?? false) else {
            replyHandler(nil, "Media document is no longer available")
            return
        }
        replyHandler(state, nil)
    }
}
