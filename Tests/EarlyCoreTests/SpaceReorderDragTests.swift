// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SpaceReorderDragTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func rejectsInvalidCatalogGeometryAndOffscreenPickup() {
        let source = ids[1]
        #expect(SpaceReorderDrag(ids: [], source: source, width: 90, viewportOffset: 0, startX: 45) == nil)
        #expect(SpaceReorderDrag(ids: [source], source: source, width: 90, viewportOffset: 0, startX: 15) == nil)
        #expect(SpaceReorderDrag(ids: [source, source], source: source, width: 90, viewportOffset: 0, startX: 15) == nil)
        #expect(SpaceReorderDrag(ids: ids, source: UUID(), width: 90, viewportOffset: 0, startX: 45) == nil)
        for width in [0.0, 29, .nan, .infinity] {
            #expect(SpaceReorderDrag(ids: ids, source: source, width: width, viewportOffset: 0, startX: 45) == nil)
        }
        #expect(SpaceReorderDrag(ids: ids, source: source, width: 90, viewportOffset: .nan, startX: 45) == nil)
        for start in [-1.0, 91, .nan, .infinity, 15] {
            #expect(SpaceReorderDrag(ids: ids, source: source, width: 90, viewportOffset: 0, startX: start) == nil)
        }
        #expect(SpaceReorderDrag(ids: ids, source: ids[4], width: 90, viewportOffset: 0, startX: 45) == nil)
    }

    @Test func previewMovesNeighborsWithoutChangingCatalogAndSupportsBothDirections() throws {
        var drag = try #require(SpaceReorderDrag(ids: ids, source: ids[1], width: 150, viewportOffset: 0, startX: 45))
        #expect(!drag.hasMoved && drag.beforeID == ids[2])
        let movedRight = drag.update(pointerX: 135)
        #expect(movedRight && drag.hasMoved)
        #expect(drag.order == [ids[0], ids[2], ids[3], ids[4], ids[1]])
        #expect(drag.beforeID == nil && drag.destinationIndex == 4)
        #expect(drag.offset(for: ids[1]) == 90)
        #expect(drag.offset(for: ids[2]) == -30 && drag.offset(for: ids[0]) == 0)
        let movedLeft = drag.update(pointerX: 15)
        #expect(movedLeft && drag.order == [ids[1], ids[0], ids[2], ids[3], ids[4]])
        #expect(drag.beforeID == ids[0] && drag.destinationIndex == 0)
        #expect(drag.offset(for: ids[0]) == 30 && drag.offset(for: ids[2]) == 0)
        #expect(drag.ids == ids && drag.offset(for: UUID()) == 0)
        drag.update(pointerX: 45)
        #expect(!drag.hasMoved && drag.order == ids)
    }

    @Test func hysteresisKeepsNeighborsStillNearInsertionBoundaries() throws {
        var drag = try #require(SpaceReorderDrag(ids: ids, source: ids[1], width: 150, viewportOffset: 0, startX: 45))
        drag.update(pointerX: 62)
        #expect(drag.destinationIndex == 1)
        drag.update(pointerX: 64)
        #expect(drag.destinationIndex == 2)
        drag.update(pointerX: 58)
        #expect(drag.destinationIndex == 2)
        drag.update(pointerX: 56)
        #expect(drag.destinationIndex == 1)
    }

    @Test func pickupKeepsItsGrabOffsetAndClampsIconToViewport() throws {
        var drag = try #require(SpaceReorderDrag(ids: ids, source: ids[1], width: 90, viewportOffset: 0, startX: 40))
        #expect(drag.offset(for: ids[1]) == 0)
        drag.update(pointerX: 55)
        #expect(drag.offset(for: ids[1]) == 15)
        drag.update(pointerX: 100)
        #expect(drag.offset(for: ids[1]) == 30)
        drag.update(pointerX: -10)
        #expect(drag.offset(for: ids[1]) == -30)
        #expect(drag.isVisible(ids[1]) && !drag.isVisible(UUID()))
    }

    @Test func edgeScrollingReachesHiddenSpacesAndKeepsSourceUnderThePointer() throws {
        let catalog = (0..<20).map { _ in UUID() }
        var drag = try #require(SpaceReorderDrag(ids: catalog, source: catalog[1], width: 90, viewportOffset: 0, startX: 45))
        drag.update(pointerX: 85)
        for _ in 0..<200 { drag.autoScrollStep() }
        #expect(drag.viewportOffset == 510 && drag.destinationIndex == 19)
        #expect(drag.beforeID == nil && drag.order.last == catalog[1])
        #expect(45 + drag.offset(for: catalog[1]) - drag.viewportOffset == 75)
        #expect(drag.isVisible(catalog[1]) && drag.isVisible(catalog[19]))
        #expect(!drag.isVisible(catalog[0]))
        #expect(Set(drag.order) == Set(catalog))
        let atEnd = drag.autoScrollStep()
        #expect(!atEnd)
        drag.update(pointerX: 5)
        for _ in 0..<200 { drag.autoScrollStep() }
        #expect(drag.viewportOffset == 0 && drag.destinationIndex == 0)
        #expect(drag.beforeID == catalog[0])
        #expect(45 + drag.offset(for: catalog[1]) == 15)
    }

    @Test func releaseOutsideStripOrInvalidPointerCancelsAndStopsEdgeScrolling() throws {
        var drag = try #require(SpaceReorderDrag(ids: ids, source: ids[1], width: 90, viewportOffset: 0, startX: 45))
        for point in [(-15.0, -8.0), (105, 40), (45, 16)] {
            drag.update(pointerX: point.0, pointerY: point.1)
            #expect(drag.canDrop)
        }
        for point in [(-16.0, 16.0), (106, 16), (85, -9), (85, 41), (.nan, 16), (85, .infinity)] {
            drag.update(pointerX: point.0, pointerY: point.1)
            #expect(!drag.canDrop)
            let offset = drag.viewportOffset
            let scrolled = drag.autoScrollStep()
            #expect(!scrolled && drag.viewportOffset == offset)
        }
        drag.update(pointerX: 45)
        #expect(drag.canDrop)
        let scrolled = drag.autoScrollStep()
        #expect(!scrolled)
    }

    @Test func narrowAndPartiallyScrolledStripUseVisiblePickupCoordinates() throws {
        var drag = try #require(SpaceReorderDrag(ids: ids, source: ids[2], width: 30, viewportOffset: 60, startX: 15))
        #expect(drag.viewportOffset == 60 && drag.offset(for: ids[2]) == 0)
        drag.update(pointerX: 28)
        for _ in 0..<30 { drag.autoScrollStep() }
        #expect(drag.viewportOffset == 120 && drag.order.last == ids[2])
        let partial = try #require(SpaceReorderDrag(ids: ids, source: ids[1], width: 90, viewportOffset: 40, startX: 5))
        #expect(partial.offset(for: ids[1]) == 10 && partial.isVisible(ids[1]))
    }
}
