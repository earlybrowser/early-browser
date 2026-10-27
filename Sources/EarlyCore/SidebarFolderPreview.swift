// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

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

    /// One outer group and one current folder, regardless of nesting depth.
    /// Geometry and hit testing still include the transparent intermediate rows.
    public static func backgroundFolderIDs(in folders: [BrowserFolder], visible: Set<UUID>,
                                           current: UUID?, hovered: Set<UUID> = []) -> Set<UUID> {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func path(from id: UUID) -> [UUID] {
            var result: [UUID] = [], next: UUID? = id, seen = Set<UUID>()
            while let id = next, let folder = byID[id], seen.insert(id).inserted {
                result.append(id); next = folder.parentID
            }
            return result
        }
        let pointer = hovered.intersection(visible).max { path(from: $0).count < path(from: $1).count }
        guard let current = pointer ?? current else { return [] }
        let branch = path(from: current).filter { visible.contains($0) }
        return Set([branch.first, branch.last].compactMap { $0 })
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

    /// Use unoffset layout headers, just like sibling insertion. Feeding drawing
    /// offsets back into this decision lets a preview push its own target away.
    public static func nestingTarget(at point: CGPoint, headers: [(id: UUID, frame: CGRect)],
                                     retaining: [UUID]) -> UUID? {
        for id in retaining {
            if let header = headers.first(where: { $0.id == id }),
               acceptsHeader(point, header: header.frame, retaining: true) { return id }
        }
        return headers.filter { acceptsHeader(point, header: $0.frame, retaining: false) }
            .min { $0.frame.height < $1.frame.height }?.id
    }

    public static func retainsPanel(_ point: CGPoint, header: CGRect, panel: CGRect,
                                    currentDepth: Int = 0, enclosingDepth: Int? = nil) -> Bool {
        // Keep small movements inside the receiving row stable, but leave the
        // upper header edge and leading gutter available for sibling placement.
        // An ancestor cannot steal a nested slot as its preview settles, but an
        // expanded descendant remains a valid, more specific destination.
        if let enclosingDepth, enclosingDepth > currentDepth { return false }
        return point.x >= header.minX + 12 && point.x <= panel.maxX + 6
            && point.y >= header.minY + 3 && point.y <= panel.maxY + 8
    }
}
