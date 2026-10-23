// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import WebKit

// MARK: Developer Mode

extension WebViewManager {
    /// Developer Mode lets Safari's Web Inspector attach to one tab's page.
    /// It is off unless asked for, and belongs to the tab, like its zoom.
    public func isDeveloperModeOn(_ id: UUID) -> Bool { developerModeTabs.contains(id) }

    public func canToggleDeveloperMode(_ id: UUID) -> Bool { pages[id] != nil }

    @discardableResult
    public func setDeveloperMode(_ on: Bool, for id: UUID) -> Bool {
        guard let page = pages[id] else { return false }
        if on { developerModeTabs.insert(id) } else { developerModeTabs.remove(id) }
        page.view.isInspectable = on
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
