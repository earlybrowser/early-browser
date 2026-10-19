// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SidebarFolderPreviewTests {
    @Test func nestingUsesTheSameLayoutSnapshotAsInsertionInsteadOfChasingItsPreview() {
        // Exact geometry of the failing CI drag: Work's center is y=248,
        // Mails is y=286, and a foreign pin previews insertion before Mails.
        let parent = UUID(), child = UUID(), source = UUID()
        let parentHeader = CGRect(x: 8, y: 231, width: 236, height: 34)
        let childHeader = CGRect(x: 20, y: 269, width: 220, height: 34)
        let point = CGPoint(x: 145, y: 286)
        let headers = [(id: parent, frame: parentHeader), (id: child, frame: childHeader)]
        let receiving = CGRect(x: 8, y: 231, width: 236, height: 120)
        let siblings = SidebarReorderLayout(source: source, slots: [
            .init(id: child, frame: childHeader),
            .init(id: source, frame: childHeader.offsetBy(dx: 0, dy: 38))
        ], bounds: receiving, grid: false, foreign: true, retainedIndex: 0)
        let offset = siblings.offset(for: child, at: point)
        #expect(offset.height == 38)
        let displayedChild = childHeader.offsetBy(dx: 0, dy: offset.height)
        // The old live-frame lookup misses the child and leaves the pin in
        // Work's newly inserted row. Waiting cannot resolve this fixed point.
        #expect(SidebarFolderPreview.nestingTarget(at: point,
            headers: [(parent, parentHeader), (child, displayedChild)], retaining: [parent]) == nil)
        #expect(SidebarFolderPreview.nestingTarget(at: point, headers: headers, retaining: [parent]) == child)
        // Entering the child removes its sibling displacement. Its one receiving
        // row and subsequent geometry/hold/release samples must keep ownership.
        for _ in 0..<20 {
            #expect(SidebarFolderPreview.nestingTarget(at: point, headers: headers, retaining: [child]) == child)
        }
        #expect(SidebarFolderPreview.nestingTarget(at: point, headers: headers, retaining: []) == child)
        // A leading gutter or top edge still permits ordering instead of nesting.
        #expect(SidebarFolderPreview.nestingTarget(at: CGPoint(x: 25, y: 286),
            headers: headers, retaining: [parent]) == nil)
        #expect(SidebarFolderPreview.nestingTarget(at: CGPoint(x: 145, y: 271),
            headers: headers, retaining: [child]) == nil)
    }

    @Test func nestingTargetRetainsItsSmallHeaderMarginButRejectsUnavailableHeaders() {
        let folder = UUID()
        let header = CGRect(x: 12, y: 100, width: 204, height: 34)
        let margin = CGPoint(x: 100, y: 104)
        #expect(SidebarFolderPreview.nestingTarget(at: margin,
            headers: [(folder, header)], retaining: []) == nil)
        #expect(SidebarFolderPreview.nestingTarget(at: margin,
            headers: [(folder, header)], retaining: [folder]) == folder)
        // Visibility/cycle checks filter the supplied headers in the view.
        #expect(SidebarFolderPreview.nestingTarget(at: margin, headers: [], retaining: [folder]) == nil)
    }

    @Test func aNestedReceivingSlotIsNotStolenByItsParentAfterTheHeaderMoves() {
        let header = CGRect(x: 12, y: 100, width: 204, height: 34)
        let panel = CGRect(x: 12, y: 100, width: 204, height: 76)
        // The pointer entered the header while a 34+4-point sibling preview
        // displaced it. After that preview clears it lies in the receiving row.
        let point = CGPoint(x: 120, y: header.midY + 38)
        #expect(SidebarFolderPreview.acceptsHeader(point,
            header: header.offsetBy(dx: 0, dy: 38), retaining: false))
        #expect(!SidebarFolderPreview.acceptsHeader(point, header: header, retaining: true))
        for enclosingDepth in [nil, 0, 1] as [Int?] {
            #expect(SidebarFolderPreview.retainsPanel(point, header: header, panel: panel,
                currentDepth: 1, enclosingDepth: enclosingDepth))
        }
        // Retention must not prevent entering an expanded, deeper descendant.
        #expect(!SidebarFolderPreview.retainsPanel(point, header: header, panel: panel,
            currentDepth: 1, enclosingDepth: 2))
        // Keep the intentional exit paths back to the parent available.
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 120, y: 102), header: header, panel: panel,
            currentDepth: 1, enclosingDepth: 0))
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 18, y: 155), header: header, panel: panel,
            currentDepth: 1, enclosingDepth: 0))
    }

    @Test func dragOutlinesOnlyAppearAboveTheTodayDividerInsideThePinsViewport() {
        let viewport = CGRect(x: 12, y: 100, width: 240, height: 800)
        let divider = CGRect(x: 12, y: 300, width: 240, height: 17)
        let today = CGPoint(x: 100, y: divider.midY + 1)
        let pins = CGPoint(x: 100, y: divider.midY - 1)
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: true, at: today, viewport: viewport, divider: divider))
        #expect(SidebarFolderPreview.showsDragTargets(isDragging: true, at: pins, viewport: viewport, divider: divider))
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: true, at: today, viewport: viewport, divider: divider))
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: true, at: CGPoint(x: 100, y: divider.midY),
            viewport: viewport, divider: divider))
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: false, at: pins, viewport: viewport, divider: divider))
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: true, at: CGPoint(x: 600, y: 200),
            viewport: viewport, divider: divider))
        #expect(!SidebarFolderPreview.showsDragTargets(isDragging: true, at: CGPoint(x: 100, y: 80),
            viewport: viewport, divider: divider)) // Favorites/address area, not Pins.
    }

    @Test func smallUpwardMovementsKeepTheSlotButItsUpperEdgeAllowsSiblingPlacement() {
        let header = CGRect(x: 0, y: 100, width: 220, height: 34)
        let panel = CGRect(x: 0, y: 100, width: 220, height: 34 + 4 + SidebarFolderPreview.dropSlotHeight)
        #expect(SidebarFolderPreview.retainsPanel(CGPoint(x: 100, y: 165), header: header, panel: panel))
        #expect(SidebarFolderPreview.retainsPanel(CGPoint(x: 100, y: 160), header: header, panel: panel))
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 100, y: 102), header: header, panel: panel))
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 100, y: 99), header: header, panel: panel))
        #expect(!SidebarFolderPreview.acceptsHeader(CGPoint(x: 100, y: 102), header: header, retaining: true))
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 5, y: 150), header: header, panel: panel))
    }

    @Test func exitingANestedSlotCanReturnToItsVisibleParentInsteadOfTheRoot() {
        let parentHeader = CGRect(x: 0, y: 20, width: 220, height: 34)
        let parentPanel = CGRect(x: 0, y: 20, width: 220, height: 200)
        let nestedHeader = CGRect(x: 12, y: 100, width: 204, height: 34)
        let nestedPanel = CGRect(x: 12, y: 100, width: 204, height: 76)
        let exit = CGPoint(x: 100, y: 102)
        #expect(!SidebarFolderPreview.retainsPanel(exit, header: nestedHeader, panel: nestedPanel))
        #expect(SidebarFolderPreview.retainsPanel(exit, header: parentHeader, panel: parentPanel))
        #expect(!SidebarFolderPreview.retainsPanel(CGPoint(x: 5, y: 102), header: parentHeader, panel: parentPanel))
    }

    @Test func hoveringAPopulatedClosedFolderShowsOneSlotButNoContents() {
        let preview = SidebarFolderPreview(isExpanded: false, hasChildren: true,
                                           isDragSource: false, receivesSlot: true)
        #expect(!preview.showsContents)
        #expect(preview.showsDropSlot)
        #expect(preview.showsPanel)
        #expect(preview.footerHeight == SidebarFolderPreview.dropSlotHeight)
    }

    @Test func manuallyExpandedFoldersKeepTheirContentsAndOnlyOneExtraRow() {
        let preview = SidebarFolderPreview(isExpanded: true, hasChildren: true,
                                           isDragSource: false, receivesSlot: true)
        #expect(preview.showsContents)
        #expect(preview.showsDropSlot)
        #expect(preview.footerHeight == SidebarFolderPreview.dropSlotHeight)
        let leaving = SidebarFolderPreview(isExpanded: true, hasChildren: true,
                                            isDragSource: false, receivesSlot: false)
        #expect(leaving.showsContents)
        #expect(!leaving.showsDropSlot)
        #expect(leaving.footerHeight == 6)
    }

    @Test func leavingAClosedFolderRemovesTheEntireTemporaryPanel() {
        for hasChildren in [false, true] {
            let preview = SidebarFolderPreview(isExpanded: false, hasChildren: hasChildren,
                                               isDragSource: false, receivesSlot: false)
            #expect(!preview.showsContents)
            #expect(!preview.showsDropSlot)
            #expect(!preview.showsPanel)
            #expect(preview.footerHeight == 0)
        }
    }

    @Test func emptyFoldersOnlyReserveSpaceWhenReceivingAnItem() {
        let idle = SidebarFolderPreview(isExpanded: true, hasChildren: false,
                                        isDragSource: false, receivesSlot: false)
        #expect(!idle.showsPanel)
        let receiving = SidebarFolderPreview(isExpanded: true, hasChildren: false,
                                             isDragSource: false, receivesSlot: true)
        #expect(!receiving.showsContents)
        #expect(receiving.showsDropSlot)
    }

    @Test func switchingTargetsReservesExactlyOneRowWithoutOpeningAnyFolder() {
        let folders = [UUID(), UUID(), UUID()]
        for target in folders.map(Optional.some) + [nil] {
            let previews = folders.map {
                SidebarFolderPreview(isExpanded: false, hasChildren: true,
                                     isDragSource: false, receivesSlot: target == $0)
            }
            #expect(previews.filter(\.showsDropSlot).count == (target == nil ? 0 : 1))
            #expect(previews.allSatisfy { !$0.showsContents })
        }
    }

    @Test func nestedPlacementDoesNotRevealChildrenOfTheHoveredFolder() {
        let parent = SidebarFolderPreview(isExpanded: true, hasChildren: true,
                                          isDragSource: false, receivesSlot: false)
        let nested = SidebarFolderPreview(isExpanded: false, hasChildren: true,
                                          isDragSource: false, receivesSlot: true)
        #expect(parent.showsContents) // Only a manually open parent makes the nested folder visible.
        #expect(!parent.showsDropSlot)
        #expect(!nested.showsContents)
        #expect(nested.showsDropSlot)
        let source = SidebarFolderPreview(isExpanded: true, hasChildren: true,
                                          isDragSource: true, receivesSlot: true)
        #expect(!source.showsPanel)
    }
}
