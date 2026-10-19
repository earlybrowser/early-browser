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
    case closeTab(UUID)
    case closeActiveTab
    case reopenLastTab
    case setPinned(UUID, Bool)
    case setFavorite(UUID, Bool)
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
    case reload
    case stop
    case toggleSidebar
    case openTabInNewWindow(UUID)
    case duplicateTab(UUID)
    case openSettings
}
