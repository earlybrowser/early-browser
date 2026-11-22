// SPDX-License-Identifier: MPL-2.0

import WebKit

@MainActor
extension WebViewManager {
    /// Removes this profile's cookies, caches and other website data changed
    /// since `date` (nil: all of it), with the cached icons of sites no longer
    /// in the sidebar. `keepingIconsFor` lists the profile's tabs, pins and
    /// Favorites. Open pages stay open; downloaded files are never touched.
    public func clearWebsiteData(since date: Date?, keepingIconsFor pages: [URL]) async {
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                          modifiedSince: date ?? .distantPast)
        await favicons.clear(since: date, keeping: pages)
    }
}
