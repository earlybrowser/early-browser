// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Keyboard tab-switcher selection contract (Control-Tab / Control-Shift-Tab).
/// Orders open tabs by most recent activation, falling back to sidebar order,
/// and commits only the chosen stable tab identity through the window's shared
/// action dispatcher. Highlighting is independent of live-page activation.
public struct TabSwitcher: Equatable, Sendable {
    public let tabIDs: [UUID]
    public let initialID: UUID?
    public private(set) var selectedIndex: Int

    public init?(openTabs: [BrowserTab], activeTabID: UUID?, initialDelta: Int = 1) {
        let ordered = Self.mruOrder(openTabs: openTabs, activeTabID: activeTabID)
        guard !ordered.isEmpty else { return nil }
        let ids = ordered.map(\.id)
        tabIDs = ids
        initialID = activeTabID
        if let start = activeTabID.flatMap({ ids.firstIndex(of: $0) }) {
            let step = initialDelta >= 0 ? 1 : -1
            selectedIndex = (start + step + ids.count) % ids.count
        } else {
            selectedIndex = initialDelta >= 0 ? 0 : ids.count - 1
        }
    }

    public var selectedTabID: UUID { tabIDs[selectedIndex] }

    public mutating func step(_ delta: Int) {
        guard !tabIDs.isEmpty, delta != 0 else { return }
        let offset = delta > 0 ? 1 : -1
        selectedIndex = (selectedIndex + offset + tabIDs.count) % tabIDs.count
    }

    public mutating func select(_ id: UUID) -> Bool {
        guard let index = tabIDs.firstIndex(of: id) else { return false }
        selectedIndex = index
        return true
    }

    /// Action to dispatch when committing the current selection, or nil when
    /// committing would stay on the already active tab.
    public var commitAction: BrowserAction? {
        let target = selectedTabID
        guard target != initialID else { return nil }
        return .selectTab(target)
    }

    /// Active tab first, then open tabs ordered by descending `lastActivatedAt`
    /// and descending `activationCount`, breaking ties by sidebar order.
    public static func mruOrder(openTabs: [BrowserTab], activeTabID: UUID?) -> [BrowserTab] {
        var seen = Set<UUID>()
        let indexed = openTabs.enumerated().filter { $0.element.isOpen && seen.insert($0.element.id).inserted }
        return indexed.sorted { lhs, rhs in
            let leftActive = lhs.element.id == activeTabID
            let rightActive = rhs.element.id == activeTabID
            if leftActive != rightActive { return leftActive }
            switch (lhs.element.lastActivatedAt, rhs.element.lastActivatedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.element.activationCount != rhs.element.activationCount {
                    return lhs.element.activationCount > rhs.element.activationCount
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
