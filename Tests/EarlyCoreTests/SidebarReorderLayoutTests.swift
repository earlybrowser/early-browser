import CoreGraphics
import Foundation
import Testing
@testable import EarlyCore

struct SidebarReorderLayoutTests {
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
    }
}
