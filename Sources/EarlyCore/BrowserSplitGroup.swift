// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Window-local layout metadata, not a second tab or a second live page owner.
public struct BrowserSplitPane: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let tabID: UUID

    public init(id: UUID = UUID(), tabID: UUID) { self.id = id; self.tabID = tabID }
}

/// Foundation for two side-by-side panes. Presentation and splitter controls
/// are added separately; storing a group must never allocate a web view.
public struct BrowserSplitGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let spaceID: UUID
    public var panes: [BrowserSplitPane]
    public var leadingFraction: Double

    public static let fractionRange = 0.2...0.8

    public init(id: UUID = UUID(), spaceID: UUID, panes: [BrowserSplitPane], leadingFraction: Double = 0.5) {
        self.id = id
        self.spaceID = spaceID
        self.panes = panes
        self.leadingFraction = leadingFraction
    }

    /// Drop unusable layout only, never tab records. A live tab may be a member
    /// of at most one group/pane in a window, including profile-wide Favorites.
    public static func pruned(_ groups: [Self], tabs: [BrowserTab], spaces: [BrowserSpace], profileID: UUID) -> [Self] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spaceIDs = Set(spaces.filter { $0.profileID == profileID }.map(\.id))
        var groupIDs = Set<UUID>(), paneIDs = Set<UUID>(), tabIDs = Set<UUID>()
        return groups.filter { group in
            let members = group.panes.map(\.tabID)
            let identities = group.panes.map(\.id)
            guard group.panes.count == 2, spaceIDs.contains(group.spaceID),
                  group.leadingFraction.isFinite, fractionRange.contains(group.leadingFraction),
                  !groupIDs.contains(group.id), Set(members).count == 2, Set(identities).count == 2,
                  tabIDs.isDisjoint(with: members), paneIDs.isDisjoint(with: identities),
                  members.allSatisfy({ id in
                      guard let tab = byID[id] else { return false }
                      return tab.profileID == profileID && tab.isOpen && tab.isVisible(in: group.spaceID)
                  }) else { return false }
            groupIDs.insert(group.id)
            paneIDs.formUnion(identities)
            tabIDs.formUnion(members)
            return true
        }
    }
}

extension BrowserSession {
    /// Split data is advisory. Missing/closed/foreign members collapse to normal
    /// tabs; invalid focus falls back to this window's selection, then the first
    /// pane. Old sessions without layout retain their existing empty/web state.
    public mutating func pruneSplitMetadata() {
        splitGroups = BrowserSplitGroup.pruned(splitGroups, tabs: tabs, spaces: spaces, profileID: profileID)
        var focus: [UUID: UUID] = [:]
        for group in splitGroups {
            let pane = group.panes.first { $0.id == focusedPaneByGroupID[group.id] }
                ?? group.panes.first { $0.tabID == selectionBySpace[group.spaceID] }
                ?? group.panes[0]
            focus[group.id] = pane.id
            if group.panes.contains(where: { $0.tabID == selectionBySpace[group.spaceID] }) {
                selectionBySpace[group.spaceID] = pane.tabID
            }
        }
        focusedPaneByGroupID = focus
    }
}
