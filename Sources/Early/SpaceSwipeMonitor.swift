// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

/// Presentation timings, not loading delays. A successful swipe should not
/// stack a long sidebar settlement in front of a slow-starting content fade.
enum SpaceSwitchMotion {
    static let contentDuration = 0.08
    static let navigationSettleDuration = 0.08
    static let cancellationSettleDuration = 0.18
}

/// AppKit chooses the performer for the current device, accessibility settings
/// and user preferences. Unsupported/disabled feedback is suppressed by macOS.
@MainActor
enum BrowserHaptics {
    private static var lastAlignment: TimeInterval = 0

    static func alignment(enabled: Bool = true) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAlignment >= 0.08 else { return }
        lastAlignment = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func pickupOrDrop(enabled: Bool = true) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// The split proposal already deduplicates activation/side changes. Do not
    /// let an immediately preceding sidebar alignment suppress this distinct cue.
    static func splitPreview(enabled: Bool = true) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Only a phased, precise scroll beginning in this sidebar can become a Space
/// swipe. The monitor never replaces page/scroll views or captures mouse wheels.
struct SpaceSwipeMonitor: NSViewRepresentable {
    let model: BrowserWindowModel
    let enabled: Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.model = model
        view.enabled = enabled
        if !enabled { view.reset() }
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        weak var model: BrowserWindowModel?
        var enabled = false
        private var monitor: Any?
        private var swipe = SpaceSwipe()
        private var contextIDs: [UUID] = []
        private var initialSpace: UUID?
        private var suppressMomentum = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func reset() {
            swipe.reset()
            contextIDs = []
            initialSpace = nil
            // Detaching/disabling can happen during a SwiftUI view update.
            // Clear presentation afterward, unless a new gesture already began.
            if let model, model.spaceSwipeCreationProgress != 0 || model.spaceSwipeProgress != 0 {
                DispatchQueue.main.async { [weak self, weak model] in
                    guard self?.initialSpace == nil, let model, !model.spaceSwipeIsSettling else { return }
                    model.finishSpaceSwipe(nil)
                }
            }
        }

        func stop() {
            reset()
            suppressMomentum = false
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if !event.momentumPhase.isEmpty {
                let suppress = suppressMomentum
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { suppressMomentum = false }
                return suppress ? nil : event
            }
            guard enabled, let model, model.canManageSpaces,
                  window.attachedSheet == nil, event.hasPreciseScrollingDeltas,
                  !event.phase.isEmpty else { reset(); return event }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.phase.contains(.began) {
                suppressMomentum = false
                guard inside else { reset(); return event }
                contextIDs = model.coordinator.spaces.map(\.id)
                initialSpace = model.coordinator.activeSpaceID
            }
            guard inside, initialSpace == model.coordinator.activeSpaceID,
                  contextIDs == model.coordinator.spaces.map(\.id),
                  let index = contextIDs.firstIndex(of: model.coordinator.activeSpaceID) else {
                reset()
                return event
            }
            let phase: SpaceSwipe.Phase
            if event.phase.contains(.cancelled) { phase = .cancelled }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.began) { phase = .began }
            else { phase = .changed }
            let update = swipe.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, phase: phase,
                canGoPrevious: index > 0, canGoNext: index + 1 < contextIDs.count)
            if model.spaceSwipeCreationProgress != update.creationProgress {
                model.spaceSwipeCreationProgress = update.creationProgress
            }
            if !event.phase.contains(.cancelled) { model.updateSpaceSwipe(translation: update.translation) }
            if update.crossedThreshold { BrowserHaptics.alignment(enabled: model.preferences.haptics) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                suppressMomentum = update.consumed
                reset()
                model.finishSpaceSwipe(update.action)
                // The scroll view may have seen the undecided beginning of
                // this gesture. Let its final phase through to finish live
                // scrolling, even when horizontal changes were intercepted.
                return event
            }
            return update.consumed ? nil : event
        }
    }
}
