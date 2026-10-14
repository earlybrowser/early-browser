import CoreGraphics

/// Drag placement does not navigate the folder tree. Only explicit expansion
/// reveals children; a receiving folder gets one temporary row instead.
public struct SidebarFolderPreview: Equatable, Sendable {
    public static let dropSlotHeight: CGFloat = 38
    public let showsContents: Bool
    public let showsDropSlot: Bool
    public var showsPanel: Bool { showsContents || showsDropSlot }
    public var footerHeight: CGFloat { showsDropSlot ? Self.dropSlotHeight : (showsContents ? 6 : 0) }

    public init(isExpanded: Bool, hasChildren: Bool, isDragSource: Bool, receivesSlot: Bool) {
        showsContents = isExpanded && hasChildren && !isDragSource
        showsDropSlot = receivesSlot && !isDragSource
    }

    public static func showsDragTargets(isDragging: Bool, at point: CGPoint,
                                       viewport: CGRect, divider: CGRect) -> Bool {
        isDragging && viewport.contains(point) && point.y < divider.midY
    }

    public static func acceptsHeader(_ point: CGPoint, header: CGRect, retaining: Bool) -> Bool {
        let inset: CGFloat = retaining ? 3 : 5
        return point.x >= header.minX + 12 && point.x <= header.maxX
            && point.y >= header.minY + inset && point.y <= header.maxY - inset
    }

    public static func retainsPanel(_ point: CGPoint, header: CGRect, panel: CGRect) -> Bool {
        // Keep small movements inside the receiving row stable, but leave the
        // upper header edge and leading gutter available for sibling placement.
        point.x >= header.minX + 12 && point.x <= panel.maxX + 6
            && point.y >= header.minY + 3 && point.y <= panel.maxY + 8
    }
}
