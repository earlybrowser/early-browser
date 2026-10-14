import Foundation
import Testing
@testable import EarlyCore

struct SidebarFolderPreviewTests {
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
