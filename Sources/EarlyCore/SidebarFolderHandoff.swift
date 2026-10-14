import CoreGraphics
import Foundation

/// Transfer a single receiving row between adjacent visible folders. Replacing
/// equal-height slots requires no pointer reprojection or opening hidden trees.
public enum SidebarFolderHandoff {
    public static func acceptsDownwardEntry(from previous: CGPoint, to point: CGPoint,
                                           departingBounds: CGRect, nextHeader: CGRect) -> Bool {
        // A small boundary corridor permits handoff before the old branch
        // collapses. Never skip a tab row, jump multiple folders, or lift a
        // leading-gutter sibling insertion into a folder accidentally.
        point.y > previous.y
            && nextHeader.minY >= departingBounds.maxY - 2
            // Up to two ancestor footer gaps can precede the next header.
            && nextHeader.minY - departingBounds.maxY <= 28
            && point.y > departingBounds.maxY + 4
            && point.y >= nextHeader.minY + 5
            && point.y <= nextHeader.maxY - 5
            && point.x >= departingBounds.minX + 12
            && point.x >= nextHeader.minX + 12
            && point.x <= nextHeader.maxX
    }
}
