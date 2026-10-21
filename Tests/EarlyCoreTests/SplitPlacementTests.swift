// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import EarlyCore
import Testing

@Suite @MainActor
struct SplitPlacementTests {
    private func browser() -> BrowserCoordinator {
        let profile = UUID(), space = UUID()
        let tabs = (0..<5).map { BrowserTab(spaceID: space, profileID: profile,
            title: "Tab \($0)", currentURL: URL(string: "https://example.com/\($0)")!) }
        return BrowserCoordinator(startup: .returningSession, activeSpaceID: space,
            tabStore: TabStore(tabs: tabs), selectionBySpace: [space: tabs[0].id], profileID: profile)
    }

    @Test(arguments: BrowserSplitSide.allCases)
    func proposalsAreReadOnlyAndCommitOnEitherSideWithoutDuplicatingTabs(_ side: BrowserSplitSide) throws {
        let browser = browser(), original = browser.session
        let active = original.tabs[0].id, source = original.tabs[1].id
        #expect(browser.splitPlacement(for: active, on: side) == nil)
        let proposal = try #require(browser.splitPlacement(for: source, on: side))
        for _ in 0..<100 { #expect(browser.splitPlacement(for: source, on: side) == proposal) }
        #expect(browser.session == original)
        #expect(proposal.tabIDs[side.index] == source)
        #expect(proposal.tabIDs[1 - side.index] == active)
        #expect(browser.applySplit(proposal))
        #expect(browser.activeSplitGroup?.panes.map(\.tabID) == proposal.tabIDs)
        #expect(browser.focusedTabID == source && browser.visibleTabIDs == [active, source])
        #expect(browser.tabStore.tabs.map(\.id) == original.tabs.map(\.id))
        try browser.session.validate()
    }

    @Test func replacementKeepsPaneIdentitiesAndLeavesTheReplacedTabOpen() throws {
        let browser = browser(), tabs = browser.session.tabs
        _ = try #require(browser.createSplit(between: tabs[0].id, and: tabs[1].id, leadingFraction: 0.65))
        let original = try #require(browser.activeSplitGroup)
        let proposal = try #require(browser.splitPlacement(for: tabs[2].id, on: .trailing))
        #expect(browser.applySplit(proposal))
        let updated = try #require(browser.activeSplitGroup)
        #expect(updated.id == original.id && updated.panes.map(\.id) == original.panes.map(\.id))
        #expect(updated.leadingFraction == 0.65 && updated.panes.map(\.tabID) == [tabs[0].id, tabs[2].id])
        #expect(browser.tabStore.tab(id: tabs[1].id)?.isOpen == true)
        #expect(browser.removeSplitPane(updated.panes[1].id))
        #expect(browser.splitGroups.isEmpty && browser.focusedTabID == tabs[0].id)
        #expect(browser.tabStore.tabs.allSatisfy { $0.isOpen })
        try browser.session.validate()
    }

    @Test func alreadyVisibleTabFocusesItsExistingPaneWithoutReordering() throws {
        let browser = browser(), tabs = browser.session.tabs
        _ = try #require(browser.createSplit(between: tabs[0].id, and: tabs[1].id))
        let group = try #require(browser.activeSplitGroup)
        let proposal = try #require(browser.splitPlacement(for: tabs[1].id, on: .leading))
        #expect(proposal.reusesExistingPane && proposal.tabIDs == group.panes.map(\.tabID))
        #expect(browser.applySplit(proposal))
        #expect(browser.activeSplitGroup == group && browser.focusedTabID == tabs[1].id)
        #expect(browser.splitGroups.count == 1)
    }

    @Test func movingATabFromAnotherGroupDetachesOnlyLayoutAndPreservesAllTabs() throws {
        let browser = browser(), tabs = browser.session.tabs
        let old = try #require(browser.createSplit(between: tabs[3].id, and: tabs[4].id))
        browser.selectOpenTab(tabs[0].id)
        _ = try #require(browser.createSplit(between: tabs[0].id, and: tabs[1].id))
        let proposal = try #require(browser.splitPlacement(for: tabs[3].id, on: .leading))
        #expect(browser.applySplit(proposal))
        #expect(!browser.splitGroups.contains { $0.id == old })
        #expect(browser.splitGroups.count == 1 && browser.visibleTabIDs == [tabs[3].id, tabs[1].id])
        #expect(browser.tabStore.tabs.map(\.id) == tabs.map(\.id) && browser.tabStore.tabs.allSatisfy { $0.isOpen })
        try browser.session.validate()
    }

    @Test func staleClosedMissingAndForeignSpaceCandidatesCannotCommit() throws {
        let browser = browser(), tabs = browser.session.tabs
        let proposal = try #require(browser.splitPlacement(for: tabs[1].id, on: .trailing))
        browser.closeTab(tabs[1].id)
        let afterClose = browser.session
        #expect(!browser.applySplit(proposal) && browser.session == afterClose)
        #expect(browser.splitPlacement(for: tabs[1].id, on: .trailing) == nil)
        #expect(browser.splitPlacement(for: UUID(), on: .trailing) == nil)
        let other = try #require(browser.createSpace(name: "Other"))
        #expect(browser.moveTab(tabs[2].id, toSpace: other))
        #expect(browser.splitPlacement(for: tabs[2].id, on: .leading) == nil)
        #expect(browser.splitGroups.isEmpty)
    }

    @Test func geometryStaysBoundedAndKeepsMinimumPaneWidthsWhenSpaceAllows() {
        for width in [0.0, 1, 120, 240, 350, 600, 1_600] {
            for fraction in [Double.nan, -.infinity, 0, 0.2, 0.5, 0.8, 1, .infinity] {
                let layout = BrowserSplitLayout(size: CGSize(width: width, height: 500), leadingFraction: fraction)
                #expect(layout.fraction.isFinite && layout.fractionRange.contains(layout.fraction))
                #expect(layout.leading.width >= 0 && layout.trailing.width >= 0)
                #expect(abs(layout.trailing.maxX - width) < 0.001)
                #expect(layout.leading.maxX == layout.divider.minX && layout.divider.maxX == layout.trailing.minX)
                if width >= 275 { #expect(layout.leading.width >= 119.999 && layout.trailing.width >= 119.999) }
            }
        }
    }

    @Test func floatingTargetsAreInsetSymmetricAndShareExactHitBoundsAtAllSizes() throws {
        for size in [CGSize(width: 240, height: 160), CGSize(width: 700, height: 600), CGSize(width: 2_000, height: 1_400)] {
            let bounds = CGRect(origin: CGPoint(x: 250, y: 6), size: size)
            let targets = try #require(BrowserSplitDropTargets(in: bounds))
            #expect(bounds.contains(targets.leading) && bounds.contains(targets.trailing))
            #expect(!targets.leading.intersects(targets.trailing))
            #expect(targets.leading.size == targets.trailing.size)
            #expect(targets.leading.minX > bounds.minX && targets.trailing.maxX < bounds.maxX)
            #expect(targets.leading.midX == bounds.minX + size.width * 0.25)
            #expect(targets.trailing.midX == bounds.minX + size.width * 0.75)
            for side in BrowserSplitSide.allCases {
                let frame = targets.frame(on: side)
                for point in [CGPoint(x: frame.midX, y: frame.midY),
                              CGPoint(x: frame.minX + 1, y: frame.minY + 1),
                              CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)] {
                    #expect(targets.side(at: point) == side)
                }
            }
            for point in [CGPoint(x: bounds.midX, y: bounds.midY),
                          CGPoint(x: bounds.minX + 1, y: bounds.midY),
                          CGPoint(x: bounds.maxX - 1, y: bounds.midY),
                          CGPoint(x: targets.leading.midX, y: bounds.minY + 1),
                          CGPoint(x: 200, y: 100), CGPoint(x: CGFloat.nan, y: 50)] {
                #expect(targets.side(at: point) == nil)
            }
        }
    }

    @Test func floatingTargetsRejectInsufficientOrNonfiniteContentBounds() {
        for bounds in [CGRect.zero, CGRect.infinite, CGRect.null,
                       CGRect(x: 0, y: 0, width: 239, height: 600),
                       CGRect(x: 0, y: 0, width: 700, height: 159),
                       CGRect(x: CGFloat.nan, y: 0, width: 700, height: 600)] {
            #expect(BrowserSplitDropTargets(in: bounds) == nil)
        }
    }

    @Test func floatingSidebarInsetKeepsBothCardsVisibleAndOutOfSidebarOrganization() throws {
        let bounds = CGRect(x: 6, y: 6, width: 900, height: 600)
        let targets = try #require(BrowserSplitDropTargets(in: bounds, leadingInset: 270))
        #expect(targets.content == CGRect(x: 276, y: 6, width: 630, height: 600))
        #expect(targets.content.contains(targets.leading) && targets.content.contains(targets.trailing))
        #expect(targets.side(at: CGPoint(x: 200, y: 306)) == nil)
        #expect(targets.side(at: CGPoint(x: targets.leading.midX, y: targets.leading.midY)) == .leading)
        for inset in [CGFloat.nan, .infinity, -1, 700, 901] {
            #expect(BrowserSplitDropTargets(in: bounds, leadingInset: inset) == nil)
        }
    }
}
