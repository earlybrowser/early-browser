// SPDX-License-Identifier: MPL-2.0

import AppKit
import WebKit

/// A new web view's blank canvas is not page content. Native hosts keep their
/// appearance background until content has painted, then use WebKit's colors.
/// Once revealed, ordinary navigation and back/forward gestures stay native.
@MainActor
public final class InitialPagePresentation: NSObject {
    @objc dynamic public private(set) var isReady = true
    private var presented = false
    private var generation = UUID()
    private var rendering = false
    private var loadCompleted = false

    func begin() {
        guard !presented else { return }
        generation = UUID()
        rendering = false
        loadCompleted = false
        isReady = false
    }

    public func reveal() {
        generation = UUID()
        presented = true
        rendering = false
        isReady = true
    }

    func processEnded() {
        reveal()
        presented = false
    }

    func finishedLoading(in view: WKWebView) {
        loadCompleted = true
        prepareForDisplay(in: view)
    }

    /// Completed blank pages and native documents may not report contentful
    /// paint. Ask WebKit for a minimal render after pending updates; never
    /// force painting for an unshown background tab.
    public func prepareForDisplay(in view: WKWebView) {
        guard !isReady, loadCompleted, !rendering, !view.isLoading, view.url != nil,
              view.window != nil, view.bounds.width >= 1, view.bounds.height >= 1 else { return }
        rendering = true
        let expected = generation
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: view.bounds.minX, y: view.bounds.minY, width: 1, height: 1)
        configuration.snapshotWidth = 1
        configuration.afterScreenUpdates = true
        view.takeSnapshot(with: configuration) { [weak self] _, _ in
            guard let self, self.generation == expected else { return }
            self.reveal()
        }
    }
}

public extension WKWebView {
    var initialPagePresentation: InitialPagePresentation? {
        (self as? BrowserWebView)?.initialPresentation
    }
}

/// Timing only: no DOM inspection, style changes, resource requests or polling.
/// The isolated world prevents websites from manufacturing a readiness signal.
@MainActor
final class PagePaintObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyInitialPaint"
    static let world = WKContentWorld.world(name: "Early.InitialPaint")
    static let script = """
    (() => {
        const state = { token: Date.now().toString(36) + Math.random().toString(36), ready: false };
        globalThis.__earlyInitialPaint = state;
        let observer;
        const ready = () => {
            if (state.ready) return;
            state.ready = true;
            observer?.disconnect();
            window.webkit.messageHandlers.earlyInitialPaint.postMessage(state.token);
        };
        try {
            if (typeof PerformanceObserver !== 'function'
                || !PerformanceObserver.supportedEntryTypes?.includes('paint')) throw new Error('Paint timing unavailable');
            observer = new PerformanceObserver(list => {
                if (list.getEntries().some(entry => entry.name === 'first-contentful-paint')) ready();
            });
            observer.observe({type: 'paint', buffered: true});
        } catch {
            document.addEventListener('DOMContentLoaded', ready, {once: true});
        }
        addEventListener('pagehide', () => observer?.disconnect(), {once: true});
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world, message.frameInfo.isMainFrame,
              let token = message.body as? String, token.count <= 64,
              let view = message.webView, let owner, let id = owner.tabID(for: view),
              let page = owner.pages[id], !page.awaitsNavigationCommit,
              let presentation = view.initialPagePresentation, !presentation.isReady else { return }
        let generation = page.navigationGeneration
        // Re-read the current isolated document. A queued signal from an old
        // document, including a same-address reload, cannot reveal its successor.
        view.evaluateJavaScript("[globalThis.__earlyInitialPaint?.token ?? '', globalThis.__earlyInitialPaint?.ready === true]",
                                in: nil, in: Self.world) { [weak owner, weak page] result in
            guard let owner, let page, owner.pages[id] === page,
                  page.navigationGeneration == generation,
                  let values = (try? result.get()) as? [Any], values.count == 2,
                  values[0] as? String == token, values[1] as? Bool == true else { return }
            presentation.reveal()
        }
    }
}
