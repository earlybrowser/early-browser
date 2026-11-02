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
        guard let capture = await sourceCapture(id) else { return nil }
        sourcePages.store(capture.source, title: capture.title, for: capture.page)
        return capture.address
    }

    /// A temporary lease keeps even an oversized source intact until the
    /// synchronous opener registers its new tab. Failed opens release it too.
    public func openPageSource(_ id: UUID, using open: (URL) -> Bool) async -> Bool {
        guard let capture = await sourceCapture(id) else { return false }
        let lease = sourcePages.lease(capture.page)
        defer { sourcePages.releaseLease(lease) }
        sourcePages.store(capture.source, title: capture.title, for: capture.page)
        return open(capture.address)
    }

    private func sourceCapture(_ id: UUID) async -> (page: URL, address: URL, title: String, source: String)? {
        guard let owner = pages[id], let page = owner.view.url,
              let address = NavigationInput.sourceURL(of: page) else { return nil }
        let generation = owner.navigationGeneration
        guard let source = await pageSource(id), pages[id] === owner,
              owner.navigationGeneration == generation, owner.view.url == page else { return nil }
        return (page, address, owner.view.title ?? "", source)
    }
}

/// `view-source:` pages: snapshots of this window's pages, shown as text. The
/// generated page runs no scripts and loads nothing, from the website or else.
@MainActor
final class PageSourcePages: NSObject, WKURLSchemeHandler {
    private struct Snapshot {
        let title: String
        let source: String
        let bytes: Int
    }
    private var snapshots: [URL: Snapshot] = [:]
    private var order: [URL] = []
    private var owners: [UUID: URL] = [:]
    private var views: [ObjectIdentifier: UUID] = [:]
    private var leases: [UUID: URL] = [:]
    private(set) var retainedBytes = 0
    var inactiveBytes: Int {
        let protected = protectedPages
        return snapshots.reduce(0) { $0 + (protected.contains($1.key) ? 0 : $1.value.bytes) }
    }
    var snapshotCount: Int { snapshots.count }
    var activeUsers: Int { owners.count }
    static let limit = 20
    /// Eight MiB keeps an ordinary inactive source available for Back/reopen,
    /// without retaining the previous 100 MiB of unused synthetic snapshots.
    /// Active source tabs are exempt: their full source must remain reloadable.
    static let inactiveByteLimit = 8 * 1024 * 1024
    private let byteLimit: Int
    static let explanation = "The page as it is now, including changes made by its scripts. Early doesn’t download it again."

    init(inactiveByteLimit: Int = PageSourcePages.inactiveByteLimit) {
        byteLimit = max(0, inactiveByteLimit)
        super.init()
    }

    func store(_ source: String, title: String, for page: URL) {
        retainedBytes -= snapshots[page]?.bytes ?? 0
        let snapshot = Snapshot(title: title, source: source, bytes: title.utf8.count + source.utf8.count)
        snapshots[page] = snapshot
        retainedBytes += snapshot.bytes
        order.removeAll { $0 == page }
        order.append(page)
        trim()
    }

    func lease(_ page: URL) -> UUID {
        let id = UUID(); leases[id] = page; return id
    }
    func releaseLease(_ id: UUID) { leases[id] = nil; trim() }

    func reconcile(_ tabs: [BrowserTab]) {
        owners = Dictionary(tabs.filter(\.isOpen).compactMap { tab in
            NavigationInput.page(ofSource: tab.currentURL).map { (tab.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        trim()
    }

    func register(_ view: WKWebView, tab: UUID, url: URL) {
        views[ObjectIdentifier(view)] = tab
        navigate(tab: tab, to: url)
    }
    func unregister(_ view: WKWebView) { views[ObjectIdentifier(view)] = nil }
    func navigate(tab: UUID, to url: URL?) {
        owners[tab] = url.flatMap(NavigationInput.page(ofSource:))
        trim()
    }
    func release(tab: UUID) { owners[tab] = nil; trim() }
    func contains(_ page: URL) -> Bool { snapshots[page] != nil }
    func clear() {
        snapshots = [:]; order = []; owners = [:]; views = [:]; leases = [:]; retainedBytes = 0
    }
    func dropInactive() {
        let protected = protectedPages
        for page in order where !protected.contains(page) { remove(page) }
        order.removeAll { snapshots[$0] == nil }
    }
    private var protectedPages: Set<URL> { Set(owners.values).union(leases.values) }
    private func remove(_ page: URL) {
        retainedBytes -= snapshots.removeValue(forKey: page)?.bytes ?? 0
    }
    private func trim() {
        let protected = protectedPages
        var unused = order.filter { !protected.contains($0) }
        var bytes = unused.reduce(0) { $0 + (snapshots[$1]?.bytes ?? 0) }
        while unused.count > Self.limit || bytes > byteLimit {
            let page = unused.removeFirst()
            bytes -= snapshots[page]?.bytes ?? 0
            remove(page)
        }
        order.removeAll { snapshots[$0] == nil }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let page = NavigationInput.page(ofSource: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if let tab = views[ObjectIdentifier(webView)] { navigate(tab: tab, to: url) }
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
        var result = ""
        appendEscaped(text, to: &result)
        return result
    }

    private static func appendEscaped(_ text: String, to result: inout String) {
        // Append complete unchanged spans and small substitutions directly to
        // the final page, rather than making four whole escaped-string copies.
        let bytes = text.utf8
        var start = bytes.startIndex, index = start
        while index < bytes.endIndex {
            let replacement: String?
            switch bytes[index] {
            case 38: replacement = "&amp;"
            case 60: replacement = "&lt;"
            case 62: replacement = "&gt;"
            case 34: replacement = "&quot;"
            default: replacement = nil
            }
            if let replacement {
                result.append(contentsOf: text[start..<index]); result.append(replacement)
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        result.append(contentsOf: text[start...])
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
        var html = "<!doctype html><meta charset=\"utf-8\">\(style)<title>Source of "
        appendEscaped(name, to: &html)
        html += "</title><header>"
        appendEscaped(explanation, to: &html)
        html += "</header><pre>"
        appendEscaped(source, to: &html)
        html += "</pre>"
        return html
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
