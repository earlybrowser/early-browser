// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing

@Suite @MainActor
struct LifecycleWorkTests {
    private func fixture() -> (WebViewManager, [BrowserTab]) {
        _ = NSApplication.shared
        let profile = UUID(), space = UUID()
        let tabs = (0..<100).map { index in
            BrowserTab(spaceID: space, profileID: profile, title: "Page \(index)",
                currentURL: URL(string: "https://example.com/\(index)")!)
        }
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        manager.reconcile(tabs: tabs)
        return (manager, tabs)
    }

    @Test func repeatedPresentationDoesNotWalkUnloadedMetadataOrAllocateViews() {
        let (manager, tabs) = fixture()
        defer { manager.discardAll() }
        manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[0].id)
        let before = manager.workMetrics.presentationVisits
        for _ in 0..<500 {
            manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[0].id)
        }
        #expect(manager.workMetrics.presentationVisits == before)
        manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[1].id)
        #expect(manager.workMetrics.presentationVisits == before + 2)
        #expect(manager.lifecycle(for: tabs[1].id).isFocused && !manager.lifecycle(for: tabs[0].id).isFocused)
        #expect(manager.lifecycles.values.filter(\.isVisible).count == 2)
        #expect(manager.liveViewCount == 0 && manager.creationCount == 0)
        manager.reconcile(tabs: [])
        #expect(manager.visibleTabIDs.isEmpty && manager.lifecycles.isEmpty)
    }

    @Test func belowBudgetSweepsNeverInspectNativeProtectionsAndKeepIdentity() {
        let (manager, tabs) = fixture()
        defer { manager.discardAll() }
        let pages = tabs.prefix(9).map { manager.prepare($0) }
        manager.setPresentation(visibleTabIDs: [tabs[0].id], focusedTabID: tabs[0].id)
        let before = manager.workMetrics.inspectedPages
        for _ in 0..<500 { #expect(manager.enforceRetention().isEmpty) }
        #expect(manager.workMetrics.inspectedPages == before)
        #expect(manager.pages[tabs[0].id] === pages[0] && manager.liveViewCount == 9)
        manager.handleMemoryPressure(.critical)
        #expect(manager.liveViewCount == 1 && manager.pages[tabs[0].id] === pages[0])
        #expect(manager.workMetrics.inspectedPages > before)
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        #expect(manager.enforceRetention() == [tabs[0].id])
        #expect(manager.liveViewCount == 0)
    }

    @Test func pressureAndProtectionStillApplyWhenExceedingTheBudget() throws {
        let (manager, tabs) = fixture()
        defer { manager.discardAll() }
        for tab in tabs.prefix(10) { manager.prepare(tab) }
        manager.setPresentation(visibleTabIDs: [tabs[0].id], focusedTabID: tabs[0].id)
        let lease = try #require(manager.protect(tabID: tabs[1].id, reason: .download))
        #expect(manager.enforceRetention() == [tabs[2].id])
        manager.handleMemoryPressure(.critical)
        #expect(Set(manager.pages.keys) == [tabs[0].id, tabs[1].id])
        manager.releaseProtection(tabID: tabs[1].id, token: lease)
        #expect(manager.enforceRetention() == [tabs[1].id])
        #expect(manager.pages[tabs[0].id] != nil)
    }
}
