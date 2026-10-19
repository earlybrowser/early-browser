// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import EarlyCore

struct CommandBarLayoutTests {
    @Test func growingInputAndResultsStayWithinShortAndTallWindows() {
        for height in [408.0, 420, 460, 600, 760, 1000] {
            for statuses in 0...2 {
                let layout = CommandBarLayout(availableHeight: height, hasSuggestions: true, statusCount: statuses)
                #expect((24...120).contains(layout.maximumInputHeight))
                #expect(layout.topInset + layout.maximumCardHeight <= height - 16)
                for input in [24.0, 60, 120, 1000, .nan] {
                    let actualInput = input.isFinite ? min(layout.maximumInputHeight, max(24, input)) : 24
                    let results = layout.suggestionHeight(inputHeight: input)
                    #expect(results >= 36 && results <= 220)
                    #expect(40 + Double(statuses) * 44 + actualInput + 25 + results <= layout.maximumCardHeight + 0.001)
                }
            }
        }
    }

    @Test func typingDoesNotMoveTheTopEdgeOrUnnecessarilyRestrictTheEditor() {
        let empty = CommandBarLayout(availableHeight: 660, hasSuggestions: false, statusCount: 0)
        let results = CommandBarLayout(availableHeight: 660, hasSuggestions: true, statusCount: 0)
        #expect(empty.topInset == results.topInset)
        #expect(empty.maximumInputHeight == 120 && results.maximumInputHeight == 120)
        #expect(empty.topInset + 32 == 660 * 0.40)
    }

    @Test func invalidGeometryAndStatusCountsStayBounded() {
        for height in [-100.0, 0, .nan, .infinity] {
            let layout = CommandBarLayout(availableHeight: height, hasSuggestions: true, statusCount: 100)
            #expect(layout.topInset.isFinite && layout.maximumCardHeight.isFinite)
            #expect(layout.maximumInputHeight >= 24)
            #expect((0...220).contains(layout.suggestionHeight(inputHeight: .infinity)))
        }
    }
}
