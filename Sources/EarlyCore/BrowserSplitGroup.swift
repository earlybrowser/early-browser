// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum BrowserSplitSide: String, CaseIterable, Sendable {
    case leading, trailing
    public var index: Int { self == .leading ? 0 : 1 }
}

/// A read-only proposal. Hovering never changes membership, selection or MRU.
public struct BrowserSplitPlacement: Equatable, Sendable {
    public let spaceID: UUID
    public let sourceTabID: UUID
    public let side: BrowserSplitSide
    public let groupID: UUID?
    public let tabIDs: [UUID]
    public let leadingFraction: Double
    public let reusesExistingPane: Bool
}

/// Geometry shared by the renderer, pointer targets, and keyboard resizing.
/// Very narrow windows retain both pages instead of silently closing a pane.
public struct BrowserSplitLayout: Equatable, Sendable {
    public let leading: CGRect
    public let trailing: CGRect
    public let divider: CGRect
    public let fractionRange: ClosedRange<Double>
    public let fraction: Double

    public init(size: CGSize, leadingFraction: Double) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        let gap = min(8, width)
        let usable = max(0, width - gap)
        let minimum = min(0.45, max(0.2, usable > 0 ? 120 / usable : 0.45))
        fractionRange = minimum...(1 - minimum)
        fraction = min(max(leadingFraction.isFinite ? leadingFraction : 0.5, minimum), 1 - minimum)
        let left = usable * fraction
        leading = CGRect(x: 0, y: 0, width: left, height: height)
        divider = CGRect(x: left, y: 0, width: gap, height: height)
        trailing = CGRect(x: left + gap, y: 0, width: max(0, usable - left), height: height)
    }

    public func frame(at index: Int) -> CGRect { index == 0 ? leading : trailing }
}

/// Floating drop cards, not edge bands. Renderer and pointer hit testing use
/// exactly the same inset rectangles, including in an auto-hidden sidebar window.
public struct BrowserSplitDropTargets: Equatable, Sendable {
    public let content: CGRect
    public let leading: CGRect
    public let trailing: CGRect

    public init?(in bounds: CGRect, leadingInset: CGFloat = 0) {
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.maxX.isFinite, bounds.maxY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, leadingInset.isFinite,
              leadingInset >= 0, bounds.width - leadingInset >= 240, bounds.height >= 160 else { return nil }
        // An auto-hidden sidebar floats over the page. Cards belong only in
        // the exposed content; organizing a tab inside that sidebar stays local.
        content = CGRect(x: bounds.minX + leadingInset, y: bounds.minY,
                         width: bounds.width - leadingInset, height: bounds.height)
        let width = min(260, content.width * 0.32)
        let height = min(440, content.height * 0.70)
        let y = content.midY - height / 2
        leading = CGRect(x: content.minX + content.width * 0.25 - width / 2,
                         y: y, width: width, height: height)
        trailing = CGRect(x: content.minX + content.width * 0.75 - width / 2,
                          y: y, width: width, height: height)
    }

    public func frame(on side: BrowserSplitSide) -> CGRect { side == .leading ? leading : trailing }

    public func side(at point: CGPoint) -> BrowserSplitSide? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        if leading.contains(point) { return .leading }
        if trailing.contains(point) { return .trailing }
        return nil
    }
}

extension BrowserCoordinator {
    public func splitPlacement(for sourceID: UUID, on side: BrowserSplitSide) -> BrowserSplitPlacement? {
        guard let source = tabStore.tab(id: sourceID), source.profileID == profileID,
              source.isOpen, source.isVisible(in: activeSpaceID), let activeID = activeTabID else { return nil }
        let group = activeSplitGroup
        let existing = group?.panes.contains { $0.tabID == sourceID } == true
        guard group != nil || sourceID != activeID else { return nil }
        var ids = group?.panes.map(\.tabID) ?? [activeID, activeID]
        if !existing { ids[side.index] = sourceID }
        guard Set(ids).count == 2 else { return nil }
        return BrowserSplitPlacement(spaceID: activeSpaceID, sourceTabID: sourceID, side: side,
            groupID: group?.id, tabIDs: ids, leadingFraction: group?.leadingFraction ?? 0.5,
            reusesExistingPane: existing)
    }
}

/// Window-local layout metadata, not a second tab or a second live page owner.
public struct BrowserSplitPane: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let tabID: UUID

    public init(id: UUID = UUID(), tabID: UUID) { self.id = id; self.tabID = tabID }
}

/// Two side-by-side panes. Storing a group never allocates a web view.
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
