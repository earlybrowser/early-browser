// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import WebKit

// MARK: Developer Mode

extension WebViewManager {
    /// macOS offers apps only Safari's Develop menu for inspecting web views.
    /// WebKit's own preference and inspector (what Safari uses) show Web
    /// Inspector in the app with Inspect Element; used only where they exist.
    static let developerExtrasPreference = "developerExtrasEnabled"
    public static let supportsWebInspector =
        WKPreferences().responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:"))
        && WKWebView.instancesRespond(to: NSSelectorFromString("_inspector"))

    /// Developer Mode: Inspect Element and Web Inspector for one tab's page,
    /// which Safari's Develop menu can also reach. Off unless asked for; it
    /// belongs to the tab, like its zoom.
    public func isDeveloperModeOn(_ id: UUID) -> Bool { developerModeTabs.contains(id) }

    public func canToggleDeveloperMode(_ id: UUID) -> Bool { pages[id] != nil }

    @discardableResult
    public func setDeveloperMode(_ on: Bool, for id: UUID) -> Bool {
        guard let page = pages[id] else { return false }
        if on { developerModeTabs.insert(id) } else { developerModeTabs.remove(id) }
        applyDeveloperMode(to: page.view, on: on)
        if !on { BrowserWebView.inspector(of: page.view)?.perform(NSSelectorFromString("close")) }
        return true
    }

    /// Also after each navigation: every document starts without the flag.
    func applyDeveloperMode(to view: WKWebView, on: Bool) {
        view.isInspectable = on
        guard Self.supportsWebInspector else { return }
        view.configuration.preferences.setValue(on, forKey: Self.developerExtrasPreference)
        (view as? BrowserWebView)?.inspectsElements = on
        view.evaluateJavaScript("window.__earlyInspectsElements = \(on)", in: nil, in: PageContextMenuObserver.world) { _ in }
    }

    public static func detachInspector(of view: WKWebView) {
        BrowserWebView.inspector(of: view)?.perform(NSSelectorFromString("detach"))
    }

    /// Opens Web Inspector for the tab, turning Developer Mode on first.
    @discardableResult
    public func showWebInspector(_ id: UUID) -> Bool {
        guard Self.supportsWebInspector, let page = pages[id] else { return false }
        if !isDeveloperModeOn(id) { setDeveloperMode(true, for: id) }
        BrowserWebView.inspector(of: page.view)?.perform(NSSelectorFromString("show"))
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
