// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Testing

struct PageLoadProgressTests {
    private final class Navigation: Sendable {}
    private let first = Navigation()
    private let second = Navigation()

    @Test func requestedLoadAndItsNativeStartShareOneCycle() {
        var progress = PageLoadProgress()
        progress.request()
        let generation = progress.generation
        // The previous document's completed estimate can arrive before start.
        progress.advance(1)
        #expect(progress.fraction == 0 && progress.isLoading)
        progress.started(ObjectIdentifier(first), expected: ObjectIdentifier(first))
        #expect(progress.generation == generation && progress.phase == .loading)
        progress.advance(0.6)
        progress.started(ObjectIdentifier(first), expected: ObjectIdentifier(first))
        #expect(progress.generation == generation && progress.fraction == 0.6)
    }

    @Test func estimatesNeverReverseOrCompleteTheVisibleCycle() {
        var progress = PageLoadProgress()
        progress.started(ObjectIdentifier(first), expected: nil)
        let generation = progress.generation
        let estimates = [0.1, 0.6, 0.3, 0, 0.5, 0.9, 1]
        let displayed = [0.1, 0.6, 0.6, 0.6, 0.6, 0.9, 0.95]
        for (estimate, expected) in zip(estimates, displayed) {
            progress.advance(estimate)
            #expect(progress.fraction == expected)
            #expect(progress.isLoading && progress.generation == generation)
        }
    }

    @Test func aGenuinePageInitiatedNavigationStartsFreshEvenDuringLoading() {
        var progress = PageLoadProgress()
        progress.started(ObjectIdentifier(first), expected: nil)
        progress.advance(0.8)
        let previous = progress.generation
        progress.started(ObjectIdentifier(second), expected: ObjectIdentifier(first))
        #expect(progress.generation != previous && progress.fraction == 0)
        progress.advance(0.2)
        #expect(progress.fraction == 0.2)
    }

    @Test func aNewRequestReplacesAnUnfinishedLoadAndIgnoresItsCompletion() {
        var progress = PageLoadProgress()
        progress.started(ObjectIdentifier(first), expected: nil)
        progress.advance(0.8)
        let previous = progress.generation
        progress.request()
        let requested = progress.generation
        progress.finish(ObjectIdentifier(first))
        #expect(requested != previous && progress.fraction == 0 && progress.phase == .requested)
        progress.started(ObjectIdentifier(second), expected: ObjectIdentifier(second))
        #expect(progress.generation == requested && progress.fraction == 0)
    }

    @Test func aDifferentNavigationStartsItsOwnCycleInsteadOfReusingThePendingRequest() {
        var progress = PageLoadProgress()
        progress.request()
        let requested = progress.generation
        progress.started(ObjectIdentifier(second), expected: ObjectIdentifier(first))
        #expect(progress.generation != requested && progress.phase == .loading)
    }

    @Test func staleCompletionCannotFinishTheCurrentNavigation() {
        var progress = PageLoadProgress()
        progress.started(ObjectIdentifier(second), expected: nil)
        progress.advance(0.4)
        progress.finish(ObjectIdentifier(first))
        #expect(progress.isLoading && progress.fraction == 0.4)
        progress.finish(ObjectIdentifier(second))
        progress.advance(0.2)
        #expect(progress.phase == .completed && progress.fraction == 1)
    }

    @Test(arguments: [false, true])
    func interruptedLoadsStayEndedDespiteLateEstimatesAndCompletion(started: Bool) {
        var progress = PageLoadProgress()
        progress.request()
        if started {
            progress.started(ObjectIdentifier(first), expected: ObjectIdentifier(first))
            progress.advance(0.4)
        }
        progress.interrupt()
        progress.advance(1)
        progress.finish(ObjectIdentifier(first))
        #expect(progress.phase == .interrupted && !progress.isLoading && progress.fraction < 1)
        let ended = progress.generation
        progress.request()
        #expect(progress.generation != ended && progress.fraction == 0 && progress.isLoading)
    }

    @Test func unknownNavigationIdentityStillAcknowledgesAnExplicitRequest() {
        var progress = PageLoadProgress()
        progress.request()
        let generation = progress.generation
        progress.started(nil, expected: nil)
        #expect(progress.generation == generation)
        progress.finish(nil)
        #expect(progress.phase == .completed)
    }

    @Test func invalidEstimatesAreBoundedWithoutMovingBackwards() {
        var progress = PageLoadProgress()
        progress.started(ObjectIdentifier(first), expected: nil)
        for estimate in [Double.nan, .infinity, -.infinity, -1] { progress.advance(estimate) }
        #expect(progress.fraction == 0)
        progress.advance(2)
        #expect(progress.fraction == 0.95)
        progress.advance(.nan)
        progress.advance(0.2)
        #expect(progress.fraction == 0.95)
    }

    @Test func anIdleSameDocumentRequestCanFinishWithoutAProvisionalStart() {
        var progress = PageLoadProgress()
        progress.request()
        let requested = progress.generation
        progress.settleRequest(atRequestedURL: true)
        #expect(progress.phase == .completed && progress.fraction == 1)
        #expect(progress.generation == requested)
        progress.started(ObjectIdentifier(first), expected: nil)
        progress.advance(0.3)
        progress.settleRequest(atRequestedURL: true)
        #expect(progress.phase == .loading && progress.fraction == 0.3)
    }

    @Test func anIdleDeclinedRequestEndsWithoutClaimingCompletion() {
        var progress = PageLoadProgress()
        progress.request()
        progress.settleRequest(atRequestedURL: false)
        #expect(progress.phase == .interrupted && progress.fraction == 0)
        progress.started(ObjectIdentifier(first), expected: nil)
        progress.advance(0.4)
        progress.settleRequest(atRequestedURL: false)
        #expect(progress.phase == .loading && progress.fraction == 0.4)
    }
}
