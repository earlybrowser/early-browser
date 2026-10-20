// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import Testing
@testable import EarlyCore

struct SidebarDragSettlementTests {
    private let released = CGRect(x: 8, y: 260, width: 240, height: 32)

    @Test func releaseKeepsTheProxyAtThePointerUntilFreshLayoutArrives() throws {
        var motion = try #require(SidebarDragSettlement(itemID: UUID(), releasedFrame: released))
        #expect(motion.frame == released && motion.opacity == 1)
        #expect(motion.animationID == nil && !motion.isComplete)
        let earlyCompletion = motion.complete(animationID: UUID())
        let staleLayout = motion.retarget(to: CGRect(x: 8, y: 60, width: 240, height: 34), visible: true, layoutID: UUID())
        #expect(!earlyCompletion && staleLayout == nil)
        #expect(motion.frame == released && motion.animationID == nil)
    }

    @Test func collapsingSectionsCanRetargetWithoutAnOldCompletionRevealingTheRow() throws {
        var motion = try #require(SidebarDragSettlement(itemID: UUID(), releasedFrame: released))
        let withTargets = CGRect(x: 8, y: 280, width: 240, height: 32)
        let final = withTargets.offsetBy(dx: 0, dy: -105.2)
        let firstTarget = motion.retarget(to: withTargets, visible: true, layoutID: motion.id)
        let first = try #require(firstTarget)
        let lastTarget = motion.retarget(to: final, visible: true, layoutID: motion.id)
        let last = try #require(lastTarget)
        #expect(first != last && motion.frame == final)
        let staleCompletion = motion.complete(animationID: first)
        #expect(!staleCompletion)
        #expect(!motion.isComplete)
        let completed = motion.complete(animationID: last)
        let repeated = motion.complete(animationID: last)
        let lateLayout = motion.retarget(to: released, visible: true, layoutID: motion.id)
        #expect(completed && !repeated && lateLayout == nil)
    }

    @Test func identicalGeometryDoesNotRestartTheLandingAnimation() throws {
        var motion = try #require(SidebarDragSettlement(itemID: UUID(), releasedFrame: released))
        let target = motion.retarget(to: released, visible: true, layoutID: motion.id)
        let animation = try #require(target)
        for _ in 0..<20 {
            let repeated = motion.retarget(to: released, visible: true, layoutID: motion.id)
            #expect(repeated == nil)
        }
        let completed = motion.complete(animationID: animation)
        #expect(motion.animationID == animation && completed)
    }

    @Test func oldLayoutAndCompletionCannotAffectANewDragOfTheSameItem() throws {
        let item = UUID()
        var previous = try #require(SidebarDragSettlement(itemID: item, releasedFrame: released))
        let target = previous.retarget(to: released, visible: true, layoutID: previous.id)
        let animation = try #require(target)
        var current = try #require(SidebarDragSettlement(itemID: item, releasedFrame: released.offsetBy(dx: 0, dy: 70)))
        #expect(previous.id != current.id)
        let staleLayout = current.retarget(to: previous.frame, visible: true, layoutID: previous.id)
        let staleCompletion = current.complete(animationID: animation)
        #expect(staleLayout == nil && !staleCompletion)
        #expect(current.animationID == nil && !current.isComplete)
    }

    @Test func hiddenDestinationFadesAtItsAncestorInsteadOfFlyingThroughTheList() throws {
        var motion = try #require(SidebarDragSettlement(itemID: UUID(), releasedFrame: released))
        let folderHeader = CGRect(x: 20, y: 90, width: 224, height: 34)
        let target = motion.retarget(to: folderHeader, visible: false, layoutID: motion.id)
        let animation = try #require(target)
        #expect(motion.frame == folderHeader && motion.opacity == 0)
        let completed = motion.complete(animationID: animation)
        #expect(completed)
    }

    @Test func cancelledDropCanReturnToItsSourceWithoutChangingIdentity() throws {
        let item = UUID()
        var motion = try #require(SidebarDragSettlement(itemID: item, releasedFrame: released))
        let source = CGRect(x: 8, y: 80, width: 240, height: 34)
        let target = motion.retarget(to: source, visible: true, layoutID: motion.id)
        let animation = try #require(target)
        #expect(motion.itemID == item && motion.frame == source && motion.opacity == 1)
        let completed = motion.complete(animationID: animation)
        #expect(completed)
    }

    @Test func invalidGeometryNeverStartsOrCorruptsASettlement() throws {
        let invalid: [CGRect] = [.zero, .null, .infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 240, height: 34),
            CGRect(x: 0, y: 0, width: 240, height: CGFloat.infinity)]
        var motion = try #require(SidebarDragSettlement(itemID: UUID(), releasedFrame: released))
        for frame in invalid {
            #expect(SidebarDragSettlement(itemID: UUID(), releasedFrame: frame) == nil)
            let retargeted = motion.retarget(to: frame, visible: true, layoutID: motion.id)
            #expect(retargeted == nil)
        }
        #expect(motion.frame == released && motion.animationID == nil)
    }
}
