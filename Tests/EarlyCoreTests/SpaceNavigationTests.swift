import Testing
@testable import EarlyCore

struct SpaceNavigationTests {
    @Test func sidebarTravelTracksFingersAndResistsOnlyTheBoundaries() {
        #expect(SpaceNavigation.sidebarTravel(translation: -60, width: 240, canGoPrevious: true, canGoNext: true) == -0.25)
        #expect(SpaceNavigation.sidebarTravel(translation: 120, width: 240, canGoPrevious: true, canGoNext: true) == 0.5)
        #expect(SpaceNavigation.sidebarTravel(translation: -500, width: 240, canGoPrevious: true, canGoNext: true) == -1)
        let edge = SpaceNavigation.sidebarTravel(translation: -180, width: 240, canGoPrevious: true, canGoNext: false)
        #expect(edge < 0 && edge > -0.24)
        #expect(SpaceNavigation.sidebarTravel(translation: 180, width: 240, canGoPrevious: false, canGoNext: true) == -edge)
        for width in [0.0, -1, .infinity, .nan] {
            #expect(SpaceNavigation.sidebarTravel(translation: -60, width: width, canGoPrevious: true, canGoNext: true) == 0)
        }
        #expect(SpaceNavigation.sidebarTravel(translation: .nan, width: 240, canGoPrevious: true, canGoNext: true) == 0)
    }

    @Test func visualTravelIsAvailableBeforeCommitAndResetsOnCancellation() {
        var swipe = SpaceSwipe()
        let first = swipe.update(x: -40, y: 0, phase: .began, canGoPrevious: false, canGoNext: true)
        #expect(first.translation == -40 && first.action == nil)
        let reversed = swipe.update(x: 25, y: 0, phase: .changed, canGoPrevious: false, canGoNext: true)
        #expect(reversed.translation == -15 && reversed.action == nil)
        #expect(swipe.update(x: 0, y: 0, phase: .cancelled, canGoPrevious: false, canGoNext: true).translation == 0)
        #expect(swipe.update(x: 0, y: 10, phase: .began, canGoPrevious: false, canGoNext: true).translation == 0)
    }

    @Test func navigationBoundsAndNumberShortcutsDoNotWrap() {
        #expect(SpaceNavigation.targetIndex(current: 0, count: 3, delta: -1) == nil)
        #expect(SpaceNavigation.targetIndex(current: 2, count: 3, delta: 1) == nil)
        #expect(SpaceNavigation.targetIndex(current: 1, count: 3, delta: -1) == 0)
        #expect(SpaceNavigation.targetIndex(current: 1, count: 3, delta: 1) == 2)
        #expect(SpaceNavigation.targetIndex(current: 0, count: 0, delta: 1) == nil)
        #expect(SpaceNavigation.targetIndex(current: -1, count: 3, delta: 1) == nil)
        #expect(SpaceNavigation.targetIndex(current: 0, count: 3, delta: Int.max) == nil)
        #expect(SpaceNavigation.shortcutIndex(number: 9, count: 3) == 2)
        #expect(SpaceNavigation.shortcutIndex(number: 9, count: 20) == 19)
        #expect(SpaceNavigation.shortcutIndex(number: 8, count: 3) == nil)
        #expect(SpaceNavigation.shortcutIndex(number: 1, count: 20) == 0)
        #expect(SpaceNavigation.shortcutIndex(number: 0, count: 20) == nil)
        #expect(SpaceNavigation.shortcutIndex(number: 9, count: 0) == nil)
    }

    @Test(arguments: [180.0, 200, 240, 340, .infinity, .nan])
    func footerKeepsEveryActiveSpaceReachableAndCapacityBounded(width: Double) {
        for count in [1, 3, 5, 6, 20, 100] {
            for active in 0..<count {
                let range = SpaceNavigation.footerRange(count: count, activeIndex: active, width: width)
                #expect(range.contains(active))
                #expect(range.lowerBound >= 0 && range.upperBound <= count)
                #expect(range.count <= 5)
                if count > 5 { #expect(range.count <= 4) }
            }
        }
        #expect(SpaceNavigation.footerRange(count: 0, activeIndex: 0, width: width).isEmpty)
    }

    @Test func deliberateSwipeOnlyCommitsOnceOnRelease() {
        var swipe = SpaceSwipe()
        let first = swipe.update(x: -40, y: 1, phase: .began, canGoPrevious: false, canGoNext: true)
        #expect(first.consumed && first.action == nil && !first.crossedThreshold)
        let armed = swipe.update(x: -40, y: 0, phase: .changed, canGoPrevious: false, canGoNext: true)
        #expect(armed.crossedThreshold && armed.action == nil)
        let further = swipe.update(x: -40, y: 0, phase: .changed, canGoPrevious: false, canGoNext: true)
        #expect(!further.crossedThreshold && further.action == nil)
        let end = swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: false, canGoNext: true)
        #expect(end.action == .next && end.consumed)
        #expect(swipe.update(x: -200, y: 0, phase: .ended, canGoPrevious: false, canGoNext: true).action == nil)
    }

    @Test func lastSpaceNeedsLongerSwipeAndCreationDoesNotFireBeforeRelease() {
        var swipe = SpaceSwipe()
        let short = swipe.update(x: -100, y: 0, phase: .began, canGoPrevious: true, canGoNext: false)
        #expect(short.creationProgress > 0 && short.creationProgress < 1)
        #expect(short.action == nil && !short.crossedThreshold)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: false).action == nil)
        let long = swipe.update(x: -180, y: 0, phase: .began, canGoPrevious: true, canGoNext: false)
        #expect(long.creationProgress == 1 && long.crossedThreshold && long.action == nil)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: false).action == .create)
    }

    @Test func outwardSwipeAtFirstBoundaryDoesNothingAndOneSpaceCanStillCreate() {
        var swipe = SpaceSwipe()
        _ = swipe.update(x: 240, y: 0, phase: .began, canGoPrevious: false, canGoNext: true)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: false, canGoNext: true).action == nil)
        _ = swipe.update(x: -200, y: 0, phase: .began, canGoPrevious: false, canGoNext: false)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: false, canGoNext: false).action == .create)
    }

    @Test func verticalAndDiagonalScrollingPassThrough() {
        var swipe = SpaceSwipe()
        #expect(!swipe.update(x: 2, y: 20, phase: .began, canGoPrevious: true, canGoNext: true).consumed)
        #expect(!swipe.update(x: -250, y: 10, phase: .changed, canGoPrevious: true, canGoNext: true).consumed)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: true).action == nil)
        #expect(!swipe.update(x: -100, y: -100, phase: .began, canGoPrevious: true, canGoNext: true).consumed)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: true).action == nil)
    }

    @Test func cancellationAndReversalDisarmEvenAfterThreshold() {
        var swipe = SpaceSwipe()
        _ = swipe.update(x: -220, y: 0, phase: .began, canGoPrevious: true, canGoNext: false)
        let cancelled = swipe.update(x: 0, y: 0, phase: .cancelled, canGoPrevious: true, canGoNext: false)
        #expect(cancelled.action == nil && cancelled.creationProgress == 0 && cancelled.consumed)
        _ = swipe.update(x: -220, y: 0, phase: .began, canGoPrevious: true, canGoNext: false)
        let reversed = swipe.update(x: 200, y: 0, phase: .changed, canGoPrevious: true, canGoNext: false)
        #expect(reversed.creationProgress < 1 && reversed.action == nil)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: false).action == nil)
    }

    @Test func reverseDirectionUsesFinalTravelAndRejectsAccidentalVerticalFinish() {
        var swipe = SpaceSwipe()
        _ = swipe.update(x: -90, y: 0, phase: .began, canGoPrevious: true, canGoNext: true)
        _ = swipe.update(x: 190, y: 0, phase: .changed, canGoPrevious: true, canGoNext: true)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: true, canGoNext: true).action == .previous)
        _ = swipe.update(x: -90, y: 0, phase: .began, canGoPrevious: true, canGoNext: true)
        #expect(swipe.update(x: 0, y: 200, phase: .ended, canGoPrevious: true, canGoNext: true).action == nil)
    }

    @Test func resetInvalidSamplesAndUnstartedSequencesCannotCommit() {
        var swipe = SpaceSwipe()
        #expect(swipe.update(x: -250, y: 0, phase: .changed, canGoPrevious: false, canGoNext: false).action == nil)
        _ = swipe.update(x: -250, y: 0, phase: .began, canGoPrevious: false, canGoNext: false)
        swipe.reset()
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: false, canGoNext: false).action == nil)
        _ = swipe.update(x: -250, y: 0, phase: .began, canGoPrevious: false, canGoNext: false)
        #expect(!swipe.update(x: .nan, y: 0, phase: .changed, canGoPrevious: false, canGoNext: false).consumed)
        #expect(swipe.update(x: 0, y: 0, phase: .ended, canGoPrevious: false, canGoNext: false).action == nil)
    }
}
