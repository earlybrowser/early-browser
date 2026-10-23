// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Typed requests shared by menu, sidebar, keyboard and command-bar entry points.
/// Availability and effects belong to the window, not to the presenting control.
public enum BrowserAction: Equatable, Sendable {
    case presentCommandBar(CommandBarIntent)
    case dismissCommandBar(restoreFocus: Bool = true)
    case submit(searchSuggestion: String? = nil)
    case selectTab(UUID)
    case selectTabNumber(Int)
    case cycleTab(Int)
    case splitTab(UUID, BrowserSplitSide)
    case focusSplitPane(UUID)
    case removeSplitPane(UUID)
    case resizeSplit(UUID, Double)
    case swapSplit(UUID)
    case exitSplit(UUID)
    case closeTab(UUID)
    case closeActiveTab
    /// Today tabs only; pins, Favorites and folders stay. All are reopenable.
    case closeOtherTabs(UUID)
    case closeTabsBelow(UUID)
    case clearTodayTabs
    case reopenLastTab
    case reopenClosedWindow
    /// One entry of History › Recently Closed, wherever it is in the list.
    case reopenRecentlyClosedTab(UUID)
    case reopenRecentlyClosedWindow(UUID)
    case showHistory
    case clearHistory
    /// A page from the History menu or window, opened as a new Today tab.
    case openHistoryPage(URL)
    case setPinned(UUID, Bool)
    case setFavorite(UUID, Bool)
    case setMuted(UUID, Bool)
    case resetPinnedTab(UUID)
    case requestRename(UUID)
    case moveTabBy(UUID, Int)
    case moveTab(UUID, toSpace: UUID)
    case moveFolder(UUID, toSpace: UUID)
    case deleteFolder(UUID)
    case switchSpace(UUID)
    case cycleSpace(Int)
    case selectSpaceNumber(Int)
    case newSpace
    case editSpace(UUID)
    case duplicateSpace(UUID)
    case deleteSpace(UUID)
    case openProfile(UUID)
    case copyCurrentURL
    case back
    case forward
    /// Jump within the focused page's back/forward list (negative is back).
    case goToHistory(offset: Int)
    case reload
    case stop
    case toggleSidebar
    case openTabInNewWindow(UUID)
    case duplicateTab(UUID)
    case openSettings
    case newWindow
    case newPrivateWindow
    case showDownloads
    case openFile
    case savePage
    case exportPDF
    case printPage
    case zoomIn
    case zoomOut
    case resetZoom
    case find
    case findNext
    case findPrevious
    case useSelectionForFind
    case toggleReader
    case toggleTranslation
    /// The focused page's current markup in a read-only window.
    case viewPageSource
    /// Shows or closes Web Inspector beside the focused tab's page.
    case toggleWebInspector
    /// Asks before removing the focused website's cookies, caches and storage.
    case clearSiteData
}
