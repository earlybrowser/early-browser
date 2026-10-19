// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One pixel displacement for a toggled folder island and its visible ancestors.
/// Shared travel keeps nested bottom padding constant throughout the rebound.
public enum SidebarFolderBounce {
    public static let rowSpacing: CGFloat = 4
    public static let peakDisplacement: CGFloat = 2.5

    public static func affectedFolders(toggling id: UUID, in folders: [BrowserFolder], hasChildren: Bool) -> Set<UUID> {
        guard hasChildren, let source = folders.first(where: { $0.id == id }) else { return [] }
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var affected: Set<UUID> = [id]
        var visited: Set<UUID> = [id]
        var parentID = source.parentID
        // Match the persisted folder tree's defensive depth ceiling, rather
        // than assuming every restored record follows today's nesting limit.
        while let id = parentID, visited.count < 32, visited.insert(id).inserted {
            guard let parent = byID[id], parent.spaceID == source.spaceID, parent.isExpanded else { break }
            affected.insert(id)
            parentID = parent.parentID
        }
        return affected
    }

    public static func displacement(_ requested: CGFloat, panelHeights: [CGFloat], minimumHeight: CGFloat) -> CGFloat {
        guard requested.isFinite, minimumHeight.isFinite, minimumHeight >= 0,
              !panelHeights.isEmpty,
              panelHeights.allSatisfy({ $0.isFinite && $0 >= minimumHeight }),
              let shortest = panelHeights.min() else { return 0 }
        // The overshoot is smaller than the inter-row gap. The return stroke
        // cannot shrink even the shortest affected island below its header.
        let minimumDisplacement = max(-0.75, minimumHeight - shortest)
        return min(peakDisplacement, max(minimumDisplacement, requested))
    }
}
