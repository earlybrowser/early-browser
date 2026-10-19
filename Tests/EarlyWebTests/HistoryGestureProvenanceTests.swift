// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import EarlyWeb
import Testing

struct HistoryGestureProvenanceTests {
    private func sample(_ gesture: inout HistoryGestureProvenance, _ phase: HistoryGestureProvenance.Phase,
                        x: CGFloat, y: CGFloat = 0, time: TimeInterval = 10, precise: Bool = true,
                        canNavigate: Bool = true) {
        gesture.update(x: x, y: y, phase: phase, precise: precise,
                       canNavigate: canNavigate, timestamp: time)
    }

    private func expectCommit(_ gesture: inout HistoryGestureProvenance, _ expected: Bool) {
        let confirmed = gesture.navigationCommitted()
        #expect(confirmed == expected)
    }

    @Test func horizontalScrollingAloneNeverConfirmsHistoryNavigation() {
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .began, x: 0)
        sample(&gesture, .changed, x: 150)
        sample(&gesture, .ended, x: 0)
        // Ordinary horizontal scrolling, including carousels/overflow pages,
        // cannot turn even an unrelated document commit into a haptic.
        expectCommit(&gesture, false)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
    }

    @Test func bothDirectionsRequireHistoryPolicyAndCommitAndOnlySignalOnce() {
        for direction: CGFloat in [-1, 1] {
            var gesture = HistoryGestureProvenance()
            sample(&gesture, .began, x: 0)
            sample(&gesture, .changed, x: direction * 30)
            sample(&gesture, .ended, x: 0)
            gesture.navigationAllowed(isBackForward: true, at: 10.1)
            expectCommit(&gesture, true)
            expectCommit(&gesture, false)
            gesture.navigationAllowed(isBackForward: true, at: 10.2)
            expectCommit(&gesture, false)
        }
    }

    @Test func mouseWheelsUnavailableHistoryAndUnlatchedChangesStaySilent() {
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .changed, x: 100)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 100, precise: false)
        sample(&gesture, .changed, x: 100)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 100, canNavigate: false)
        sample(&gesture, .changed, x: 100)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
    }

    @Test func verticalDiagonalAndUnrelatedNavigationsDoNotQualify() {
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .began, x: 1, y: 20)
        sample(&gesture, .changed, x: 100) // Vertical scrolling stays vertically latched.
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 20, y: 20)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: false, at: 10)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
    }

    @Test func cancellationExpiryAndOtherInputClearTheCandidateAndPendingCommit() {
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .began, x: 50)
        sample(&gesture, .cancelled, x: 0)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: true, at: 11.01)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 50)
        gesture.reset() // Click, key, button, detachment, stop or navigation failure.
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        gesture.reset()
        expectCommit(&gesture, false)
    }

    @Test func releaseAfterPolicyDoesNotEraseAConfirmedSlowNavigation() {
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        sample(&gesture, .ended, x: 0, time: 10.1)
        // Once matched to an allowed action, loading duration must not matter.
        expectCommit(&gesture, true)
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        sample(&gesture, .began, x: 0, time: 11)
        expectCommit(&gesture, false)
    }

    @Test func discreteTrackpadSwipesAlsoRequireConfirmedHistoryNavigation() {
        for direction: CGFloat in [-1, 1] {
            var gesture = HistoryGestureProvenance()
            gesture.discreteSwipe(x: direction, y: 0, canNavigate: true, timestamp: 10)
            gesture.navigationAllowed(isBackForward: true, at: 10.1)
            expectCommit(&gesture, true)
            gesture.discreteSwipe(x: 0, y: direction, canNavigate: true, timestamp: 10)
            gesture.navigationAllowed(isBackForward: true, at: 10.1)
            expectCommit(&gesture, false)
            gesture.discreteSwipe(x: direction, y: 0, canNavigate: false, timestamp: 10)
            gesture.navigationAllowed(isBackForward: true, at: 10.1)
            expectCommit(&gesture, false)
        }
    }

    @Test func invalidSamplesAndNonmonotonicTimeCannotConfirmNavigation() {
        for value in [Double.nan, .infinity, -.infinity] {
            var gesture = HistoryGestureProvenance()
            sample(&gesture, .began, x: 50)
            sample(&gesture, .changed, x: 1, time: value)
            gesture.navigationAllowed(isBackForward: true, at: 10)
            expectCommit(&gesture, false)
            sample(&gesture, .began, x: value)
            gesture.navigationAllowed(isBackForward: true, at: 10)
            expectCommit(&gesture, false)
            gesture.discreteSwipe(x: value, y: 0, canNavigate: true, timestamp: 10)
            gesture.navigationAllowed(isBackForward: true, at: 10)
            expectCommit(&gesture, false)
            sample(&gesture, .began, x: 50)
            gesture.navigationAllowed(isBackForward: true, at: value)
            expectCommit(&gesture, false)
        }
        var gesture = HistoryGestureProvenance()
        sample(&gesture, .began, x: 50)
        sample(&gesture, .changed, x: 1, time: 9)
        gesture.navigationAllowed(isBackForward: true, at: 10)
        expectCommit(&gesture, false)
        sample(&gesture, .began, x: 50)
        gesture.navigationAllowed(isBackForward: true, at: 9)
        expectCommit(&gesture, false)
    }
}
