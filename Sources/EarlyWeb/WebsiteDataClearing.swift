// SPDX-License-Identifier: MPL-2.0

import WebKit

@MainActor
extension WebViewManager {
    /// Removes this profile's cookies, caches and other website data changed
    /// since `date` (nil: all of it), with its cached icons and thumbnails.
    /// Open pages stay open; downloaded files are never touched.
    public func clearWebsiteData(since date: Date?) async {
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                          modifiedSince: date ?? .distantPast)
        if !ephemeral { await FaviconStore.removeCachedIcons(for: profileID, since: date) }
        forgetClearedArtwork()
    }

    /// Another window of the profile cleared the shared data.
    public func forgetClearedArtwork() {
        favicons.forgetAll()
        snapshots.clear()
    }
}
