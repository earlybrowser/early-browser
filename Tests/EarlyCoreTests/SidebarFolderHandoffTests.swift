import CoreGraphics
import Foundation
import Testing
@testable import EarlyCore

struct SidebarFolderHandoffTests {
    @Test func downwardExitHandsOffAcrossAdjacentHeaderAndAncestorFooterGaps() {
        let departing = CGRect(x: 0, y: 20, width: 220, height: 120)
        for gap in [CGFloat(4), 14, 24] {
            let next = CGRect(x: 0, y: departing.maxY + gap, width: 220, height: 30)
            #expect(SidebarFolderHandoff.acceptsDownwardEntry(
                from: CGPoint(x: 100, y: 139), to: CGPoint(x: 100, y: next.minY + 6),
                departingBounds: departing, nextHeader: next))
        }
        let next = CGRect(x: 0, y: 144, width: 220, height: 30)
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 100, y: 139), to: CGPoint(x: 100, y: 143),
            departingBounds: departing, nextHeader: next)) // Still in the old branch.
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 100, y: 139), to: CGPoint(x: 100, y: 145),
            departingBounds: departing, nextHeader: next)) // Header edge remains sibling insertion.
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 100, y: 160), to: CGPoint(x: 100, y: 150),
            departingBounds: departing, nextHeader: next)) // Upward motion.
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 5, y: 139), to: CGPoint(x: 5, y: 150),
            departingBounds: departing, nextHeader: next)) // Lift-out gutter.
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 16, y: 139), to: CGPoint(x: 16, y: 150),
            departingBounds: departing.offsetBy(dx: 12, dy: 0), nextHeader: next)) // Nested lift-out.
        #expect(!SidebarFolderHandoff.acceptsDownwardEntry(
            from: CGPoint(x: 100, y: 160), to: CGPoint(x: 100, y: 199),
            departingBounds: departing, nextHeader: next.offsetBy(dx: 0, dy: 40))) // Not adjacent.
    }

    @Test func replacingOneReceivingSlotKeepsThePointerInsideTheNextFolder() {
        let slot = SidebarFolderPreview.dropSlotHeight
        let first = CGRect(x: 0, y: 20, width: 220, height: 34)
        let departing = CGRect(x: 0, y: first.minY, width: 220, height: first.height + 4 + slot)
        let next = CGRect(x: 0, y: departing.maxY + 4, width: 220, height: 34)
        let pointer = CGPoint(x: 100, y: next.minY + 7)
        #expect(SidebarFolderHandoff.acceptsDownwardEntry(from: CGPoint(x: 100, y: departing.maxY - 1),
            to: pointer, departingBounds: departing, nextHeader: next))
        let movedHeader = next.offsetBy(dx: 0, dy: -(slot + 4))
        let receivingPanel = CGRect(x: movedHeader.minX, y: movedHeader.minY,
            width: movedHeader.width, height: movedHeader.height + 4 + slot)
        #expect(receivingPanel.contains(pointer)) // The real pointer, without a hidden coordinate offset.
    }
}
