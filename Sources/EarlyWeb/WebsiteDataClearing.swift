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
        if !ephemeral { await FaviconStore.removeCachedIcons(for: profileID, since: date, keeping: pages) }
        forgetClearedArtwork(keepingIconsFor: pages)
    }

    /// Another window of the profile cleared the shared data. Tab thumbnails
    /// belong to open tabs only, so they stay.
    public func forgetClearedArtwork(keepingIconsFor pages: [URL]) {
        favicons.forget(keeping: pages)
    }
}
