// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Activation feedback never delays the action or the actual Reload/Stop state.
struct NavigationButton: View {
    let kind: NavigationControlStyle.Kind
    /// Back and Forward list the tab's history on right-click or press-and-hold.
    var history: (() -> [WebViewManager.HistoryListEntry])? = nil
    var onHistory: (Int) -> Void = { _ in }
    let action: () -> Void
    @State private var activation = 0
    @State private var clickFeedback = false
    /// Back and Forward's history overlay takes the pointer, so it reports
    /// hover and press for the button underneath to show.
    @State private var overlayHovered = false
    @State private var overlayPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { activate() } label: {
            ReloadStopArtwork(isLoading: kind == .stop)
        }
        .buttonStyle(NavigationControlStyle(kind: kind, clickFeedback: clickFeedback,
                                            hovered: overlayHovered, pressed: overlayPressed))
        .overlay {
            if let history, isEnabled {
                HistoryMenuOverlay(onClick: activate, entries: history, onSelect: onHistory,
                                   onHover: { overlayHovered = $0 }, onPress: { overlayPressed = $0 })
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { overlayHovered = false; overlayPressed = false }
        }
        .browserKeyboardFocus(cornerRadius: 8)
        .task(id: activation) {
            guard activation > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                clickFeedback = false
            } catch { /* A newer activation or disappearing view cancels feedback. */ }
        }
    }

    private func activate() {
        clickFeedback = !reduceMotion
        activation += 1
        action()
    }
}

/// Native press-and-hold and right-click for Back and Forward. A click shorter
/// than the hold delay is an ordinary Back/Forward; keyboard and VoiceOver use
/// the SwiftUI button underneath.
struct HistoryMenuOverlay: NSViewRepresentable {
    let onClick: () -> Void
    let entries: () -> [WebViewManager.HistoryListEntry]
    let onSelect: (Int) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> HistoryMenuView { HistoryMenuView() }
    func updateNSView(_ view: HistoryMenuView, context: Context) {
        view.onClick = onClick
        view.entries = entries
        view.onSelect = onSelect
        view.onHover = onHover
        view.onPress = onPress
    }
    static func dismantleNSView(_ view: HistoryMenuView, coordinator: ()) {
        view.cancelHold()
        view.onHover(false)
        view.onPress(false)
    }

    final class HistoryMenuView: NSView {
        static let holdDelay: TimeInterval = 0.4
        var onClick: () -> Void = {}
        var entries: () -> [WebViewManager.HistoryListEntry] = { [] }
        var onSelect: (Int) -> Void = { _ in }
        var onHover: (Bool) -> Void = { _ in }
        var onPress: (Bool) -> Void = { _ in }
        private var hold: Timer?
        private var showedMenu = false
        private var tracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func isAccessibilityElement() -> Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// This view is on top of the button, so the button's own hover
        /// never fires: the pointer is tracked here instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) {
            showedMenu = false
            cancelHold()
            onPress(true)
            hold = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showMenu() }
            }
        }

        override func mouseUp(with event: NSEvent) {
            let wasHolding = hold != nil
            cancelHold()
            onPress(false)
            if wasHolding, !showedMenu, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
        }

        override func rightMouseDown(with event: NSEvent) {
            cancelHold()
            showMenu()
        }

        func cancelHold() {
            hold?.invalidate()
            hold = nil
        }

        func makeMenu() -> NSMenu? {
            let list = entries()
            guard !list.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in list {
                let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = entry.offset
                item.toolTip = entry.url.absoluteString
                menu.addItem(item)
            }
            return menu
        }

        private func showMenu() {
            cancelHold()
            onPress(false)
            guard let menu = makeMenu() else { return }
            showedMenu = true
            // Just below the button.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
        }

        @objc private func choose(_ sender: NSMenuItem) { onSelect(sender.tag) }
    }
}

struct ReloadStopArtwork: View {
    let isLoading: Bool
    @State private var motion: NavigationSymbolMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isLoading: Bool) {
        self.isLoading = isLoading
        _motion = State(initialValue: NavigationSymbolMotion(isLoading: isLoading))
    }

    var body: some View {
        Color.clear.frame(width: 24, height: 24)
            .modifier(motion)
            .clipped()
            .onChange(of: isLoading) { _, loading in
                // Animate one persistent pair of glyphs, never insertion/removal
                // transitions. Fast loads can retarget forward through the X
                // without resetting or unwinding the rotation.
                withAnimation(reduceMotion ? nil : .linear(duration: 0.16)) {
                    motion.setLoading(loading)
                }
            }
    }
}

/// One increasing phase controls both glyphs and their shared rotation. Reload
/// is visible at even phases, X at odd phases: a complete cycle turns 360°.
struct NavigationSymbolMotion: ViewModifier, Animatable {
    // SwiftUI interpolates this value outside the view's main-actor context.
    nonisolated var phase: Double

    init(isLoading: Bool) { phase = isLoading ? 1 : 0 }
    init(phase: Double) { self.phase = phase }

    mutating func setLoading(_ loading: Bool) {
        let wasLoading = !Int(phase).isMultiple(of: 2)
        guard loading != wasLoading else { return }
        phase += 1
    }

    nonisolated var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var rotationDegrees: Double { phase * 180 }
    var reloadOpacity: Double {
        let cycle = phase.truncatingRemainder(dividingBy: 2)
        return (1 + cos(cycle * .pi)) / 2
    }
    var stopOpacity: Double { 1 - reloadOpacity }

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18).opacity(reloadOpacity)
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18).opacity(stopOpacity)
                }
                .rotationEffect(.degrees(rotationDegrees), anchor: .center)
                .accessibilityHidden(true)
            }
    }
}

/// Native button activation/focus semantics with a fixed hit area. Only the
/// artwork moves; hovering never shifts adjacent controls or triggers navigation.
struct NavigationControlStyle: ButtonStyle {
    enum Kind { case back, forward, reload, stop }
    let kind: Kind
    var clickFeedback = false
    /// Hover and press reported by a view laid over the button.
    var hovered = false
    var pressed = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, kind: kind, clickFeedback: clickFeedback,
                   overlayHovered: hovered, overlayPressed: pressed)
    }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let clickFeedback: Bool
        let overlayHovered: Bool
        let overlayPressed: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var highlighted: Bool { isEnabled && (hovered || overlayHovered) }
        private var pressed: Bool { isEnabled && (configuration.isPressed || overlayPressed) }

        var body: some View {
            ZStack {
                if kind == .back || kind == .forward {
                    NavigationChevron(openness: highlighted && !reduceMotion ? 1 : 0,
                                      pointsRight: kind == .forward)
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 18)
                        .offset(x: !reduceMotion && (pressed || clickFeedback)
                                ? (kind == .back ? -1 : 1) * (clickFeedback ? 3 : 1.5) : 0)
                } else {
                    configuration.label
                }
            }
            .scaleEffect((kind == .back || kind == .forward) && pressed && !reduceMotion ? 0.88 : 1)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(pressed ? 0.13 : (highlighted ? 0.075 : 0)),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: highlighted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: clickFeedback)
        }
    }
}

struct NavigationChevron: Shape {
    var openness: CGFloat
    let pointsRight: Bool
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Bring the tip toward the ends to open the chevron's interior angle.
        let tip = 0.24 + 0.05 * openness
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (pointsRight ? 1 - x : x),
                    y: rect.minY + rect.height * y)
        }
        return Path { path in
            path.move(to: point(0.72, 0.16))
            path.addLine(to: point(tip, 0.5))
            path.addLine(to: point(0.72, 0.84))
        }
    }
}
