import Foundation
import WebKit

/// Runtime ownership boundary. Phase 0 deliberately has no creation path.
/// Phase 1 will configure a profile data store before allocating each view.
@MainActor
final class WebViewManager {
    private var views: [UUID: WKWebView] = [:]

    var liveViewCount: Int { views.count }

    func existingView(for tabID: UUID) -> WKWebView? { views[tabID] }

    func discard(tabID: UUID) {
        guard let view = views.removeValue(forKey: tabID) else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    func discardAll() {
        for id in Array(views.keys) { discard(tabID: id) }
    }
}
