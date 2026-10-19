// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SidebarFolderBounceTests {
    @Test func togglingNestedContentsIncludesOnlyTheVisibleAncestorChain() {
        let space = UUID()
        let outer = BrowserFolder(spaceID: space, name: "Outer", isExpanded: true)
        let middle = BrowserFolder(spaceID: space, parentID: outer.id, name: "Middle", isExpanded: true)
        let inner = BrowserFolder(spaceID: space, parentID: middle.id, name: "Inner")
        let sibling = BrowserFolder(spaceID: space, parentID: outer.id, name: "Sibling", isExpanded: true)
        let unrelated = BrowserFolder(spaceID: space, name: "Other", isExpanded: true)
        let affected = SidebarFolderBounce.affectedFolders(toggling: inner.id,
            in: [outer, middle, inner, sibling, unrelated], hasChildren: true)
        #expect(affected == [outer.id, middle.id, inner.id])
        #expect(SidebarFolderBounce.affectedFolders(toggling: outer.id,
            in: [outer, middle, inner], hasChildren: true) == [outer.id])
    }

    @Test func emptyFoldersAndMissingIDsNeverBounceEvenWithExpandedAncestors() {
        let outer = BrowserFolder(spaceID: UUID(), name: "Outer", isExpanded: true)
        let empty = BrowserFolder(spaceID: outer.spaceID, parentID: outer.id, name: "Empty")
        #expect(SidebarFolderBounce.affectedFolders(toggling: empty.id, in: [outer, empty], hasChildren: false).isEmpty)
        #expect(SidebarFolderBounce.affectedFolders(toggling: UUID(), in: [outer, empty], hasChildren: true).isEmpty)
        #expect(SidebarFolderBounce.affectedFolders(toggling: empty.id, in: [], hasChildren: true).isEmpty)
    }

    @Test func closedForeignAndMissingAncestorsStopTheVisibleChain() {
        let space = UUID()
        let outer = BrowserFolder(spaceID: space, name: "Outer", isExpanded: true)
        let closed = BrowserFolder(spaceID: space, parentID: outer.id, name: "Closed")
        let inner = BrowserFolder(spaceID: space, parentID: closed.id, name: "Inner", isExpanded: true)
        #expect(SidebarFolderBounce.affectedFolders(toggling: inner.id,
            in: [outer, closed, inner], hasChildren: true) == [inner.id])
        let foreign = BrowserFolder(spaceID: UUID(), parentID: outer.id, name: "Foreign", isExpanded: true)
        let crossSpace = BrowserFolder(spaceID: space, parentID: foreign.id, name: "Cross-Space")
        #expect(SidebarFolderBounce.affectedFolders(toggling: crossSpace.id,
            in: [outer, foreign, crossSpace], hasChildren: true) == [crossSpace.id])
        #expect(SidebarFolderBounce.affectedFolders(toggling: inner.id,
            in: [inner], hasChildren: true) == [inner.id])
    }

    @Test func corruptCyclesDuplicateRecordsAndOverdeepTreesAreBounded() {
        let space = UUID(), firstID = UUID(), secondID = UUID()
        let first = BrowserFolder(id: firstID, spaceID: space, parentID: secondID, name: "First", isExpanded: true)
        let second = BrowserFolder(id: secondID, spaceID: space, parentID: firstID, name: "Second", isExpanded: true)
        #expect(SidebarFolderBounce.affectedFolders(toggling: first.id,
            in: [first, second, first], hasChildren: true) == [first.id, second.id])
        let selfCycle = BrowserFolder(id: firstID, spaceID: space, parentID: firstID, name: "Self", isExpanded: true)
        #expect(SidebarFolderBounce.affectedFolders(toggling: selfCycle.id,
            in: [selfCycle], hasChildren: true) == [selfCycle.id])
        var chain: [BrowserFolder] = []
        for index in 0..<50 {
            chain.append(BrowserFolder(spaceID: space, parentID: chain.last?.id, name: "Folder \(index)", isExpanded: true))
        }
        let affected = SidebarFolderBounce.affectedFolders(toggling: chain.last!.id, in: chain, hasChildren: true)
        #expect(affected.count == 32 && affected.contains(chain.last!.id))
    }

    @Test func positiveTravelNeverClosesTheGapToTheNextSibling() {
        let minimum: CGFloat = 34
        for heights: [CGFloat] in [[34], [34.25], [70], [1000], [34, 80, 600]] {
            for requested: CGFloat in [0, 0.4, 2, 2.5, 4, 1000] {
                let delta = SidebarFolderBounce.displacement(requested, panelHeights: heights, minimumHeight: minimum)
                #expect(delta >= 0 && delta <= SidebarFolderBounce.peakDisplacement)
                #expect(SidebarFolderBounce.rowSpacing - delta > 0)
                for height in heights {
                    let siblingTop = height + SidebarFolderBounce.rowSpacing
                    #expect(height + delta < siblingTop)
                }
            }
        }
    }

    @Test func returnStrokeRespectsTheShortestHeaderAndSharesItsClamp() {
        let minimum: CGFloat = 34
        #expect(SidebarFolderBounce.displacement(-1, panelHeights: [70, 150], minimumHeight: minimum) == -0.75)
        #expect(SidebarFolderBounce.displacement(-1, panelHeights: [34.25, 150], minimumHeight: minimum) == -0.25)
        #expect(SidebarFolderBounce.displacement(-1, panelHeights: [34, 150], minimumHeight: minimum) == 0)
        for heights: [CGFloat] in [[34], [34.25, 90], [70, 150, 1000]] {
            for requested: CGFloat in [-1000, -1, -0.75, -0.2, 0] {
                let delta = SidebarFolderBounce.displacement(requested, panelHeights: heights, minimumHeight: minimum)
                #expect(delta >= -0.75 && delta <= 0)
                #expect(heights.allSatisfy { $0 + delta >= minimum })
            }
        }
    }

    @Test func sharedPixelTravelPreservesNestedBottomPaddingAtEveryFrame() {
        let heights: [CGFloat] = [70, 146, 260]
        let padding = zip(heights.dropFirst(), heights).map { $0.0 - $0.1 }
        for requested: CGFloat in [0, 1.5, 2.5, 1, -0.75, -0.25, 0] {
            let delta = SidebarFolderBounce.displacement(requested, panelHeights: heights, minimumHeight: 34)
            let adjusted = heights.map { $0 + delta }
            #expect(zip(adjusted.dropFirst(), adjusted).map { $0.0 - $0.1 } == padding)
            for (original, changed) in zip(heights, adjusted) { #expect(changed - original == delta) }
        }
    }

    @Test func invalidGeometryProducesNoBounce() {
        for requested: CGFloat in [.nan, .infinity, -.infinity] {
            #expect(SidebarFolderBounce.displacement(requested, panelHeights: [70], minimumHeight: 34) == 0)
        }
        for minimum: CGFloat in [.nan, .infinity, -.infinity, -1] {
            #expect(SidebarFolderBounce.displacement(2, panelHeights: [70], minimumHeight: minimum) == 0)
        }
        for heights: [CGFloat] in [[], [33], [-1], [.nan], [.infinity], [70, .nan], [70, 33]] {
            #expect(SidebarFolderBounce.displacement(2, panelHeights: heights, minimumHeight: 34) == 0)
        }
    }
}
