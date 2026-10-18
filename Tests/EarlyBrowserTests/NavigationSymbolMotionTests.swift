// SPDX-License-Identifier: MPL-2.0

@testable import EarlyBrowser
import Testing

@MainActor
struct NavigationSymbolMotionTests {
    @Test func fullClockwiseCycleShowsStopAtTheMidpoint() {
        var motion = NavigationSymbolMotion(isLoading: false)
        #expect(motion.rotationDegrees == 0 && motion.reloadOpacity == 1)
        motion.setLoading(true)
        #expect(motion.rotationDegrees == 180 && motion.stopOpacity == 1)
        motion.setLoading(false)
        #expect(motion.rotationDegrees == 360 && motion.reloadOpacity == 1)

        let loadingAtLaunch = NavigationSymbolMotion(isLoading: true)
        #expect(loadingAtLaunch.stopOpacity == 1)
    }

    @Test func bothSymbolsShareOneContinuousClockwiseTimeline() {
        let frames = (0...16).map { NavigationSymbolMotion(phase: Double($0) / 8) }
        for frame in frames {
            #expect((0...1).contains(frame.reloadOpacity))
            #expect((0...1).contains(frame.stopOpacity))
            #expect(frame.reloadOpacity + frame.stopOpacity == 1)
        }
        for (before, after) in zip(frames, frames.dropFirst()) {
            #expect(after.rotationDegrees > before.rotationDegrees)
        }
        #expect(frames.last!.rotationDegrees - frames.first!.rotationDegrees == 360)
    }

    @Test func fastAndRepeatedLoadingChangesNeverResetOrReverseTheRotation() {
        var motion = NavigationSymbolMotion(isLoading: false)
        let changes = [true, true, false, false, true, false]
        let expected = [1.0, 1, 2, 2, 3, 4]
        for (loading, phase) in zip(changes, expected) {
            let previous = motion.rotationDegrees
            motion.setLoading(loading)
            #expect(motion.phase == phase)
            #expect(motion.rotationDegrees >= previous)
            #expect(loading ? motion.stopOpacity == 1 : motion.reloadOpacity == 1)
        }
    }

    @Test func interpolatedPhaseDrivesTheRotationAndCrossfadeTogether() {
        var motion = NavigationSymbolMotion(isLoading: false)
        motion.animatableData = 0.5
        #expect(motion.rotationDegrees == 90)
        #expect(abs(motion.reloadOpacity - 0.5) < 0.000_001)
        #expect(abs(motion.stopOpacity - 0.5) < 0.000_001)
        motion.animatableData = 1.5
        #expect(motion.rotationDegrees == 270)
        #expect(abs(motion.reloadOpacity - 0.5) < 0.000_001)
        #expect(abs(motion.stopOpacity - 0.5) < 0.000_001)
    }
}
