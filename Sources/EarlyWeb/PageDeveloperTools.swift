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
        guard let page = pages[id], page.view.url != nil, page.failure == nil else { return false }
        return page.documentMIMEType != "application/pdf"
    }

    public func pageSource(_ id: UUID) async -> String? {
        guard canShowPageSource(id), let view = pages[id]?.view else { return nil }
        return try? await view.callAsyncJavaScript(Self.pageSourceScript, contentWorld: Self.documentWorld) as? String
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
