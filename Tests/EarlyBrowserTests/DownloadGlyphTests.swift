// SPDX-License-Identifier: MPL-2.0

@testable import EarlyBrowser
import SwiftUI
import Testing

struct DownloadGlyphTests {
    @Test func artworkMatchesTheWebsitesTwentyFourPointGrid() {
        let path = DownloadGlyph().path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.boundingRect == CGRect(x: 3, y: 3, width: 18, height: 18))
        var starts: [CGPoint] = []
        var end: CGPoint?
        path.forEach { element in
            switch element {
            case let .move(to: point): starts.append(point)
            case let .line(to: point): end = point
            default: break
            }
        }
        #expect(starts == [CGPoint(x: 21, y: 15), CGPoint(x: 7, y: 10), CGPoint(x: 12, y: 15)])
        #expect(end == CGPoint(x: 12, y: 3))
    }

    @Test func artworkScalesUniformlyAndCentersInItsFrame() {
        let glyph = DownloadGlyph()
        let footer = glyph.path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
        #expect(footer.boundingRect == CGRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5))
        let wide = glyph.path(in: CGRect(x: 10, y: 20, width: 48, height: 24))
        #expect(wide.boundingRect == CGRect(x: 25, y: 23, width: 18, height: 18))
    }
}
