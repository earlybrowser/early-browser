// SPDX-License-Identifier: MPL-2.0

import EarlyCore
@testable import EarlyBrowser
import Testing

@MainActor
struct PageLoadingIndicatorTests {
    @Test func oneCycleAdvancesThenHidesAfterItsCompletion() {
        var progress = PageLoadProgress()
        var presentation = PageLoadingIndicatorState()
        progress.request()
        presentation.update(progress)
        #expect(presentation.isVisible && presentation.fraction == 0)
        progress.started(nil, expected: nil)
        progress.advance(0.7)
        presentation.update(progress)
        progress.advance(0.2)
        presentation.update(progress)
        #expect(presentation.isVisible && presentation.fraction == 0.7)
        progress.finish(nil)
        presentation.update(progress)
        #expect(presentation.isVisible && presentation.fraction == 1)
        presentation.hide(completed: progress.generation)
        presentation.update(progress)
        #expect(!presentation.isVisible)
    }

    @Test func attachingAnAlreadyCompletedBackgroundPageDoesNotFlashTheLine() {
        var progress = PageLoadProgress()
        progress.started(nil, expected: nil)
        progress.finish(nil)
        var presentation = PageLoadingIndicatorState()
        presentation.update(progress)
        #expect(!presentation.isVisible)
    }

    @Test func theOldCompletionTimerCannotHideAReplacementNavigation() {
        var progress = PageLoadProgress()
        var presentation = PageLoadingIndicatorState()
        progress.started(nil, expected: nil)
        presentation.update(progress)
        progress.finish(nil)
        presentation.update(progress)
        let completed = progress.generation
        progress.request()
        presentation.update(progress)
        presentation.hide(completed: completed)
        #expect(presentation.isVisible && presentation.fraction == 0)
        #expect(presentation.generation == progress.generation)
    }

    @Test func stoppingOrFailingHidesWithoutPretendingToComplete() {
        var progress = PageLoadProgress()
        var presentation = PageLoadingIndicatorState()
        progress.started(nil, expected: nil)
        progress.advance(0.6)
        presentation.update(progress)
        progress.interrupt()
        presentation.update(progress)
        #expect(!presentation.isVisible && presentation.fraction == 0.6)
    }
}
