// SPDX-License-Identifier: MPL-2.0

@testable import EarlyBrowser
import SwiftUI
import Testing

struct DownloadGlyphTests {
    @Test func artworkMatchesTheWebsitesTwentyFourPointGrid() {
        let path = DownloadGlyph().path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.boundingRect == CGRect(x: 3, y: 3, width: 18, height: 18))
    }

    @Test func artworkScalesUniformlyAndCentersInItsFrame() {
        let glyph = DownloadGlyph()
        let footer = glyph.path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
        #expect(footer.boundingRect == CGRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5))
        let wide = glyph.path(in: CGRect(x: 10, y: 20, width: 48, height: 24))
        #expect(wide.boundingRect == CGRect(x: 25, y: 23, width: 18, height: 18))
    }

    @Test func circleAndArrowPartsLineUpWithTheWholeArtwork() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        #expect(DownloadGlyph(part: .circle).path(in: rect).boundingRect == CGRect(x: 3, y: 3, width: 18, height: 18))
        #expect(DownloadGlyph(part: .arrow).path(in: rect).boundingRect == CGRect(x: 8.5, y: 7.75, width: 7, height: 7.75))
    }

    @Test func droppedArrowStaysInsideTheRingAtRestAndHidesFullyAtBothEnds() {
        let size: CGFloat = 18
        let cap = 1.75 * size / 24 / 2
        let arrow = DownloadGlyph(part: .arrow).path(in: CGRect(x: 0, y: 0, width: size, height: size)).boundingRect
            .insetBy(dx: -cap, dy: -cap)
        let radius = size / 2 - DownloadArrowDrop.maskInset
        let center = CGPoint(x: size / 2, y: size / 2)
        for corner in [CGPoint(x: arrow.minX, y: arrow.minY), CGPoint(x: arrow.maxX, y: arrow.minY),
                       CGPoint(x: arrow.minX, y: arrow.maxY), CGPoint(x: arrow.maxX, y: arrow.maxY)] {
            #expect(hypot(corner.x - center.x, corner.y - center.y) < radius, "Unclipped at rest")
        }
        #expect(arrow.minY + DownloadArrowDrop.travel >= size - DownloadArrowDrop.maskInset, "Gone below the circle")
        #expect(arrow.maxY - DownloadArrowDrop.travel <= DownloadArrowDrop.maskInset, "Starts above the circle")
        #expect(DownloadArrowDrop.startScale * size <= 28, "Grows within the button's frame")
    }
}
