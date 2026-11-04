// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

/// Keep the final edge visible briefly. A new navigation cancels the previous
/// completion task, so it cannot hide the new navigation's indicator.
struct PageLoadingIndicator: View {
    let progress: PageLoadProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation = PageLoadingIndicatorState()

    var body: some View {
        GeometryReader { geometry in
            if presentation.isVisible {
                Rectangle().fill(Color.accentColor)
                    .frame(width: geometry.size.width * presentation.fraction)
                    .accessibilityLabel("Page loading")
                    .accessibilityValue("\(Int(presentation.fraction * 100)) percent")
                    .accessibilityIdentifier("browser.loading")
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .task(id: progress) {
            // Reset a genuinely new navigation without animating backwards.
            let animation: Animation? = progress.generation == presentation.generation && !reduceMotion
                ? .linear(duration: 0.12) : nil
            withAnimation(animation) { presentation.update(progress) }
            guard progress.phase == .completed else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            presentation.hide(completed: progress.generation)
        }
    }
}

struct PageLoadingIndicatorState {
    private(set) var generation: UUID?
    private(set) var fraction = 0.0
    private(set) var isVisible = false

    mutating func update(_ progress: PageLoadProgress) {
        if generation != progress.generation {
            generation = progress.generation
            fraction = 0
            // An already completed background page must not flash on attachment.
            isVisible = progress.isLoading
        }
        if progress.isLoading {
            isVisible = true
            fraction = max(fraction, progress.fraction)
        } else if progress.phase == .completed {
            if isVisible { fraction = 1 }
        } else {
            isVisible = false
        }
    }

    mutating func hide(completed generation: UUID) {
        guard self.generation == generation else { return }
        isVisible = false
    }
}
