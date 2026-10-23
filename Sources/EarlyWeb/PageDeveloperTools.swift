// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import WebKit

// MARK: Web Inspector

extension WebViewManager {
    /// macOS offers apps only Safari's Develop menu for inspecting web views.
    /// WebKit's own preference and inspector, the ones Safari uses, show Web
    /// Inspector in the app, with Inspect Element; used only where they exist.
    static let developerExtrasPreference = "developerExtrasEnabled"
    public static let supportsWebInspector =
        WKPreferences().responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:"))
        && WKWebView.instancesRespond(to: NSSelectorFromString("_inspector"))

    /// Every page can be inspected, as in Chrome. Without WebKit's inspector,
    /// Safari's Develop menu can inspect it instead.
    static func enableInspection(_ preferences: WKPreferences) {
        if supportsWebInspector { preferences.setValue(true, forKey: developerExtrasPreference) }
    }

    static func enableInspection(_ view: WKWebView) {
        if supportsWebInspector { (view as? BrowserWebView)?.inspectsElements = true }
        else { view.isInspectable = true }
    }

    /// WebKit keeps the inspector's dock side in the app's defaults. It opens
    /// docked on the right unless the person has chosen otherwise.
    public static func registerInspectorDefaults(in defaults: UserDefaults = .standard) {
        let group = "__WebInspectorPageGroupLevel1__."
        defaults.register(defaults: [group + "WebKit2InspectorStartsAttached": true,
                                     group + "WebKit2InspectorAttachmentSide": 1,
                                     group + "WebKit2InspectorAttachedWidth": 460])
    }

    public func canToggleWebInspector(_ id: UUID) -> Bool { Self.supportsWebInspector && pages[id] != nil }

    public func isWebInspectorVisible(_ id: UUID) -> Bool {
        guard let view = pages[id]?.view else { return false }
        return BrowserWebView.inspector(of: view)?.value(forKey: "isVisible") as? Bool == true
    }

    /// Shows Web Inspector docked beside the page, or closes it.
    @discardableResult
    public func toggleWebInspector(_ id: UUID) -> Bool {
        guard canToggleWebInspector(id), let view = pages[id]?.view, let inspector = BrowserWebView.inspector(of: view) else { return false }
        if isWebInspectorVisible(id) {
            inspector.perform(NSSelectorFromString("close"))
        } else {
            inspector.perform(NSSelectorFromString("show"))
        }
        return true
    }
}

// MARK: View Page Source

extension WebViewManager {
    /// The document as it is now, with its scripts' changes, read from a world
    /// the page cannot reach. Nothing is fetched from the website again.
    static let pageSourceScript = """
        return (document.doctype ? new XMLSerializer().serializeToString(document.doctype) + '\\n' : '')
            + document.documentElement.outerHTML;
        """

    public func canShowPageSource(_ id: UUID) -> Bool {
        guard let page = pages[id], let url = page.view.url, page.failure == nil else { return false }
        return page.documentMIMEType != "application/pdf" && url.scheme?.lowercased() != NavigationInput.pageSourceScheme
    }

    public func pageSource(_ id: UUID) async -> String? {
        guard canShowPageSource(id), let view = pages[id]?.view else { return nil }
        return try? await view.callAsyncJavaScript(Self.pageSourceScript, contentWorld: Self.documentWorld) as? String
    }

    /// Keeps the page's current markup for its `view-source:` tab and returns
    /// that tab's address.
    public func capturePageSource(_ id: UUID) async -> URL? {
        guard let view = pages[id]?.view, let page = view.url, let address = NavigationInput.sourceURL(of: page),
              let source = await pageSource(id) else { return nil }
        sourcePages.store(source, title: view.title ?? "", for: page)
        return address
    }
}

/// `view-source:` pages: snapshots of this window's pages, shown as text. The
/// generated page runs no scripts and loads nothing, from the website or else.
@MainActor
final class PageSourcePages: NSObject, WKURLSchemeHandler {
    private var snapshots: [URL: (title: String, source: String)] = [:]
    private var order: [URL] = []
    static let limit = 20
    static let explanation = "The page as it is now, including changes made by its scripts. Early doesn’t download it again."

    func store(_ source: String, title: String, for page: URL) {
        snapshots[page] = (title, source)
        order.removeAll { $0 == page }
        order.append(page)
        while order.count > Self.limit { snapshots[order.removeFirst()] = nil }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let page = NavigationInput.page(ofSource: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let html = snapshots[page].map { Self.render($0.source, title: $0.title, page: page) } ?? Self.unavailable(page)
        let headers = ["Content-Type": "text/html; charset=utf-8",
                       "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
        <meta name="color-scheme" content="light dark"><style>
        body { margin: 0; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        header { position: sticky; top: 0; padding: 10px 14px; font: 13px -apple-system, sans-serif; color: GrayText;
                 background: Canvas; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
        pre { margin: 0; padding: 12px 14px; white-space: pre-wrap; overflow-wrap: anywhere; tab-size: 4; }
        p { font: 14px -apple-system, sans-serif; padding: 24px; }
        </style>
        """

    static func render(_ source: String, title: String, page: URL) -> String {
        let name = title.isEmpty ? (page.host ?? page.absoluteString) : title
        return "<!doctype html><meta charset=\"utf-8\">\(style)<title>Source of \(escape(name))</title>"
            + "<header>\(escape(explanation))</header><pre>\(escape(source))</pre>"
    }

    static func unavailable(_ page: URL) -> String {
        "<!doctype html><meta charset=\"utf-8\">\(style)<title>Source of \(escape(page.host ?? page.absoluteString))</title>"
            + "<p>This source view wasn’t kept. Open <a href=\"\(escape(page.absoluteString))\">\(escape(page.absoluteString))</a> "
            + "and choose View Page Source again.</p>"
    }
}

// MARK: Clear Cache and Cookies

extension WebViewManager {
    /// One website's cookies, caches and storage in this profile: the data
    /// records of its domain and subdomains. Other websites are untouched.
    @discardableResult
    public func clearWebsiteData(forHost host: String) async -> Int {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await websiteDataStore.dataRecords(ofTypes: types).filter { Self.dataRecord($0.displayName, belongsTo: host) }
        guard !records.isEmpty else { return 0 }
        await websiteDataStore.removeData(ofTypes: types, for: records)
        return records.count
    }

    /// WebKit names records by their site, such as "example.com" for
    /// "www.example.com"; another site that merely ends the same way is not it.
    public static func dataRecord(_ name: String, belongsTo host: String) -> Bool {
        let name = name.lowercased(), host = host.lowercased()
        guard !name.isEmpty, !host.isEmpty else { return false }
        return host == name || host.hasSuffix("." + name) || name.hasSuffix("." + host)
    }
}
