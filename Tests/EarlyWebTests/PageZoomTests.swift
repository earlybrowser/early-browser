// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Testing

@Suite(.serialized) @MainActor
struct PageZoomTests {
    @Test func zoomStepsThroughSafariLevelsAndSnapsInBetweenValues() {
        #expect(WebViewManager.zoomLevel(after: 1, step: 1) == 1.15)
        #expect(WebViewManager.zoomLevel(after: 1, step: -1) == 0.85)
        #expect(WebViewManager.zoomLevel(after: 1.2, step: 1) == 1.25)
        #expect(WebViewManager.zoomLevel(after: 1.2, step: -1) == 1.15)
        #expect(WebViewManager.zoomLevel(after: 3, step: 1) == nil && WebViewManager.zoomLevel(after: 0.5, step: -1) == nil)
    }

    @Test func zoomBelongsToTheTabSurvivesMemoryDiscardAndIsForgottenWhenClosed() async throws {
        let fixture = PageToolFixture(pages: ["one": "<p>One</p>", "two": "<p>Two</p>"], allowance: 0)
        defer { fixture.cleanup() }
        let one = try await fixture.open("one")
        let two = try await fixture.open("two")
        let manager = fixture.manager
        #expect(!manager.canResetZoom(one.id) && manager.canZoom(one.id, by: 1))
        for expected in [1.15, 1.25, 1.5, 1.75, 2, 2.5, 3] {
            #expect(manager.zoom(one.id, by: 1))
            #expect(try fixture.page(one).zoom == expected && fixture.page(one).view.pageZoom == expected)
        }
        #expect(!manager.canZoom(one.id, by: 1) && !manager.zoom(one.id, by: 1), "300% is the largest step")
        #expect(try fixture.page(two).zoom == 1, "Zoom is per tab, not per site or window")
        #expect(manager.resetZoom(one.id) && !manager.canResetZoom(one.id))
        #expect(manager.zoom(one.id, by: -1) && manager.zoom(one.id, by: -1))
        #expect(try fixture.page(one).zoom == 0.75)

        // Memory discard keeps the choice for the recreated view.
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        #expect(Set(manager.enforceRetention()) == [one.id, two.id])
        let recreated = manager.prepare(one)
        #expect(recreated.zoom == 0.75 && recreated.view.pageZoom == 0.75)

        // Closing the tab forgets it.
        manager.reconcile(tabs: [two])
        #expect(manager.prepare(one).zoom == 1)
    }
}
