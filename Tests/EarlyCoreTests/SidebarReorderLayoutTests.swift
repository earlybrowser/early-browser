import CoreGraphics
import Foundation
import Testing
@testable import EarlyCore

struct SidebarReorderLayoutTests {
    @Test func favoritesRetainTheirSettledColumnAcrossSmallPointerMovements() {
        let first = UUID(), second = UUID(), source = UUID()
        let slots: [SidebarReorderLayout.Slot] = [
            .init(id: first, frame: CGRect(x: 0, y: 0, width: 54, height: 43.2)),
            .init(id: second, frame: CGRect(x: 60, y: 0, width: 54, height: 43.2)),
            .init(id: source, frame: CGRect(x: 120, y: 0, width: 54, height: 43.2))
        ]
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 100)
        let before = SidebarReorderLayout(source: source, slots: slots, bounds: bounds,
                                          grid: true, retainedIndex: 0)
        #expect(before.order(at: CGPoint(x: 29, y: 20)) == [source, first, second])
        #expect(before.order(at: CGPoint(x: 34, y: 20)) == [first, source, second])
        let after = SidebarReorderLayout(source: source, slots: slots, bounds: bounds,
                                         grid: true, retainedIndex: 1)
        #expect(after.order(at: CGPoint(x: 25, y: 20)) == [first, source, second])
        #expect(after.order(at: CGPoint(x: 20, y: 20)) == [source, first, second])
        #expect(after.order(at: CGPoint(x: 170, y: 20)) == [first, second, source])
    }

    @Test func settledInsertionDoesNotFlipWhenThePointerWobblesAcrossAMidpoint() {
        let first = UUID(), second = UUID(), source = UUID()
        let slots: [SidebarReorderLayout.Slot] = [
            .init(id: first, frame: CGRect(x: 0, y: 0, width: 240, height: 32)),
            .init(id: second, frame: CGRect(x: 0, y: 36, width: 240, height: 32)),
            .init(id: source, frame: CGRect(x: 0, y: 72, width: 240, height: 32))
        ]
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 240)
        let above = SidebarReorderLayout(source: source, slots: slots, bounds: bounds,
                                         grid: false, retainedIndex: 1)
        for y in [CGFloat(49), 52, 54, 57] {
            let point = CGPoint(x: 80, y: y)
            #expect(above.order(at: point) == [first, source, second])
            #expect(above.insertion(at: point)?.before == second)
            #expect(above.offset(for: second, at: point).height == 36)
        }
        #expect(above.order(at: CGPoint(x: 80, y: 59)) == [first, second, source])
        let below = SidebarReorderLayout(source: source, slots: slots, bounds: bounds,
                                         grid: false, retainedIndex: 2)
        for y in [CGFloat(55), 52, 50, 47] {
            #expect(below.order(at: CGPoint(x: 80, y: y)) == [first, second, source])
        }
        #expect(below.order(at: CGPoint(x: 80, y: 45)) == [first, source, second])
        // Intentional large moves and cancellation remain immediate.
        #expect(below.order(at: CGPoint(x: 80, y: 2)) == [source, first, second])
        #expect(above.order(at: CGPoint(x: 80, y: 180)) == [first, second, source])
        #expect(above.insertion(at: CGPoint(x: 300, y: 50)) == nil)
    }

    @Test func everySourceContainerClosesItsGapWhenAnItemLeaves() {
        let parent = UUID(), otherParent = UUID()
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: nil,
            destinationSection: .pinned, destinationFolder: parent))
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .regular, sourceFolder: nil,
            destinationSection: .pinned, destinationFolder: nil))
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: nil,
            destinationSection: .favorites, destinationFolder: nil))
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: parent,
            destinationSection: .pinned, destinationFolder: otherParent))
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: parent,
            destinationSection: .pinned, destinationFolder: nil))
        #expect(SidebarReorderLayout.vacatesSourceRow(sourceSection: .regular, sourceFolder: nil,
            destinationSection: nil, destinationFolder: nil))
        // Same-container reorders use the existing source slot, not two gaps.
        #expect(!SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: nil,
            destinationSection: .pinned, destinationFolder: nil))
        #expect(!SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: parent,
            destinationSection: .pinned, destinationFolder: parent))
        #expect(!SidebarReorderLayout.vacatesSourceRow(sourceSection: .regular, sourceFolder: nil,
            destinationSection: .regular, destinationFolder: nil))
    }

    @Test func linearInsertionUsesExpandedFolderBlockHeights() {
        let folder = UUID(), next = UUID(), source = UUID()
        let layout = SidebarReorderLayout(source: source, slots: [
            .init(id: folder, frame: CGRect(x: 10, y: 20, width: 240, height: 120),
                  hitFrame: CGRect(x: 10, y: 20, width: 240, height: 34)),
            .init(id: next, frame: CGRect(x: 10, y: 144, width: 240, height: 34)),
            .init(id: source, frame: CGRect(x: 10, y: 182, width: 240, height: 34))
        ], bounds: CGRect(x: 10, y: 20, width: 240, height: 280), grid: false, foreign: true)
        let before = CGPoint(x: 30, y: 21)
        #expect(layout.insertion(at: before)?.before == folder)
        #expect(layout.offset(for: folder, at: before).height == 38)
        let between = CGPoint(x: 30, y: 142)
        #expect(layout.insertion(at: between)?.before == next)
        #expect(layout.offset(for: next, at: between).height == 38)
        let after = CGPoint(x: 30, y: 250)
        #expect(layout.insertion(at: after)?.before == nil)
        #expect(layout.insertion(at: CGPoint(x: 300, y: 100)) == nil)
    }

    @Test func unchangedInsertionDoesNotCommitOrShiftNeighbors() {
        let first = UUID(), source = UUID()
        let slots: [SidebarReorderLayout.Slot] = [
            .init(id: first, frame: CGRect(x: 0, y: 0, width: 240, height: 32)),
            .init(id: source, frame: CGRect(x: 0, y: 36, width: 240, height: 32))
        ]
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 200)
        let point = CGPoint(x: 80, y: 50)
        let layout = SidebarReorderLayout(source: source, slots: slots, bounds: bounds, grid: false)
        #expect(layout.order(at: point) == [first, source])
        #expect(layout.offset(for: first, at: point) == .zero)
        #expect(layout.insertion(at: point) == nil)
    }

    @Test func favoritesUseEqualColumnsIncludingPartialLastRows() {
        let bounds = CGRect(x: 10, y: 20, width: 240, height: 180)
        for count in [1, 2, 3, 4, 5, 6, 7] {
            let frames = SidebarReorderLayout.favoriteFrames(count: count, in: bounds)
            for start in stride(from: 0, to: count, by: 4) {
                let row = Array(frames[start..<min(start + 4, count)])
                #expect(row.first?.minX == bounds.minX)
                if row.count == min(4, count) {
                    #expect(row.last?.maxX == bounds.maxX)
                } else {
                    #expect((row.last?.maxX ?? 0) < bounds.maxX)
                }
                #expect(row.allSatisfy { $0.width == frames[0].width && $0.height == SidebarReorderLayout.favoriteHeight })
            }
        }
        let ids = (0..<5).map { _ in UUID() }
        let frames = SidebarReorderLayout.favoriteFrames(count: 5, in: bounds)
        let layout = SidebarReorderLayout(source: ids[4], slots: zip(ids, frames).map {
            .init(id: $0.0, frame: $0.1)
        }, bounds: bounds, grid: true, foreign: true)
        #expect(layout.insertion(at: CGPoint(x: bounds.minX + 2, y: frames[0].midY))?.before == ids[0])
        #expect(layout.insertion(at: CGPoint(x: bounds.midX, y: frames[4].midY))?.before == nil)
    }

    @Test func expandedFolderAndForeignInsertionUseBlockHeights() {
        let folder = UUID(), tab = UUID(), source = UUID()
        let layout = SidebarReorderLayout(source: source, slots: [
            .init(id: folder, frame: CGRect(x: 0, y: 0, width: 200, height: 104),
                  hitFrame: CGRect(x: 0, y: 0, width: 200, height: 32)),
            .init(id: tab, frame: CGRect(x: 0, y: 108, width: 200, height: 32)),
            .init(id: source, frame: CGRect(x: 0, y: 144, width: 200, height: 32))
        ], bounds: CGRect(x: 0, y: 0, width: 200, height: 200), grid: false, foreign: true)
        let top = CGPoint(x: 20, y: 2)
        #expect(layout.insertion(at: top)?.before == folder)
        #expect(layout.offset(for: folder, at: top).height == 36)
        #expect(layout.offset(for: tab, at: top).height == 36)
        #expect(layout.insertion(at: CGPoint(x: 20, y: 106))?.before == tab)
        #expect(layout.insertion(at: CGPoint(x: 20, y: 195))?.before == nil)
    }

    @Test func previewShiftsBothDirectionsAndAcceptsGapsAndEmptySpace() {
        let ids = (0..<3).map { _ in UUID() }
        let slots = ids.enumerated().map { SidebarReorderLayout.Slot(id: $0.element,
            frame: CGRect(x: 0, y: $0.offset * 36, width: 240, height: 32)) }
        let layout = SidebarReorderLayout(source: ids[2], slots: slots,
                                         bounds: CGRect(x: 0, y: 0, width: 240, height: 400), grid: false)
        let gap = CGPoint(x: 80, y: 34)
        #expect(layout.order(at: gap) == [ids[0], ids[2], ids[1]])
        #expect(layout.offset(for: ids[1], at: gap).height == 36)
        #expect(layout.drop(at: gap)?.target == ids[0])
        #expect(layout.order(at: CGPoint(x: 80, y: 2)) == [ids[2], ids[0], ids[1]])
        let reverse = SidebarReorderLayout(source: ids[0], slots: slots, bounds: layout.bounds, grid: false)
        let emptySpace = CGPoint(x: 80, y: 200)
        #expect(reverse.order(at: emptySpace) == [ids[1], ids[2], ids[0]])
        #expect(reverse.offset(for: ids[1], at: emptySpace).height == -36)
        #expect(reverse.drop(at: emptySpace)?.after == true)
        #expect(reverse.drop(at: CGPoint(x: 280, y: 50)) == nil)
        #expect(reverse.order(at: CGPoint(x: 280, y: 50)) == ids)
        #expect(reverse.offset(for: ids[1], at: CGPoint(x: 280, y: 50)) == .zero)
    }

    @Test func favoritePreviewMovesAcrossGridRows() {
        let ids = (0..<5).map { _ in UUID() }
        let slots = ids.enumerated().map { SidebarReorderLayout.Slot(id: $0.element,
            frame: CGRect(x: ($0.offset % 4) * 60, y: ($0.offset / 4) * 60, width: 54, height: 54)) }
        let layout = SidebarReorderLayout(source: ids[4], slots: slots,
                                         bounds: CGRect(x: 0, y: 0, width: 240, height: 114), grid: true)
        let point = CGPoint(x: 2, y: 20)
        #expect(layout.order(at: point) == [ids[4], ids[0], ids[1], ids[2], ids[3]])
        #expect(layout.offset(for: ids[3], at: point) == CGSize(width: -180, height: 60))
        // Dragging out closes the source gap immediately, including row wraps.
        let leaving = SidebarReorderLayout(source: ids[1], slots: slots, bounds: layout.bounds, grid: true)
        #expect(leaving.offsetRemovingSource(for: ids[0]) == .zero)
        #expect(leaving.offsetRemovingSource(for: ids[1]) == .zero)
        #expect(leaving.offsetRemovingSource(for: ids[2]) == CGSize(width: -60, height: 0))
        #expect(leaving.offsetRemovingSource(for: ids[4]) == CGSize(width: 180, height: -60))
        #expect(layout.offsetRemovingSource(for: ids[3]) == .zero) // Last tile leaves no interior gap.
        // Re-entry at the original slot restores the ordinary, unshifted preview.
        #expect(leaving.offset(for: ids[2], at: CGPoint(x: 85, y: 20)) == .zero)
        let incoming = SidebarReorderLayout(source: ids[1], slots: slots, bounds: layout.bounds, grid: true, foreign: true)
        #expect(incoming.offsetRemovingSource(for: ids[2]) == .zero)
    }
}
