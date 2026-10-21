// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

/// Bounded by the content surface, including a narrow window with a wide sidebar.
struct TabSwitcherLayout: Equatable {
    let panelWidth: Double
    let cardWidth: Double
    static let spacing = 8.0

    init(availableWidth: Double, count: Int) {
        let available = availableWidth.isFinite ? max(1, availableWidth - 32) : 320
        let maximum = min(960, available)
        cardWidth = min(192, max(1, maximum - 24))
        let boundedCount = max(0, count)
        panelWidth = min(maximum, Double(boundedCount) * cardWidth
                         + Double(max(0, boundedCount - 1)) * Self.spacing + 24)
    }
}

struct TabSwitcherView: View {
    @Bindable var model: BrowserWindowModel
    let availableWidth: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: UUID?

    var body: some View {
        if let selection = model.tabSwitcher {
            let layout = TabSwitcherLayout(availableWidth: availableWidth, count: selection.tabIDs.count)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: TabSwitcherLayout.spacing) {
                        ForEach(selection.tabIDs, id: \.self) { id in
                            if let tab = model.coordinator.tabStore.tab(id: id) {
                                card(tab, width: layout.cardWidth, selected: selection.selectedTabID == id)
                                    .id(id)
                            }
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
                .frame(width: layout.panelWidth, height: max(1, (layout.cardWidth - 16) * 0.625) + 70)
                .onChange(of: selection.selectedTabID, initial: true) { _, id in
                    // No animated traversal through dozens of intermediate cards.
                    reader.scrollTo(id, anchor: .center)
                }
            }
            .background {
                if model.preferences.spaceThemes, contrast != .increased {
                    BrowserChromeBackground(spaceColor: model.coordinator.activeSpace?.color ?? .gray,
                        floating: true, allowsTransparency: model.preferences.translucentChrome)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else if reduceTransparency || !model.preferences.translucentChrome || contrast == .increased {
                    RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 20).fill(.thickMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : (colorScheme == .dark ? 0.32 : 0.18)), radius: 24, y: 8)
            .background(TabSwitcherCardBoundary(model: model))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tab switcher")
            .accessibilityHint("Use arrow keys to preview, Return to switch, or Escape to cancel")
            .accessibilityIdentifier("tabSwitcher")
        }
    }

    private func card(_ tab: BrowserTab, width: Double, selected: Bool) -> some View {
        Button { model.commitTabSwitcher(selecting: tab.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    // Cache reads only: no snapshot request, page resume, or
                    // favicon network work occurs just to present a candidate.
                    if let preview = model.webViews.snapshots.image(for: tab.id) {
                        Image(nsImage: preview).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 22, weight: .light))
                            Text("Preview unavailable").font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: max(1, width - 16), height: max(1, (width - 16) * 0.625))
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                HStack(spacing: 7) {
                    Group {
                        if let icon = model.webViews.favicons.image(for: tab.currentURL) {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                    Text(tab.displayTitle).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
            }
            .padding(8)
            .frame(width: width)
            .background(Color.primary.opacity(selected ? 0.13 : (hoveredID == tab.id ? 0.07 : 0.025)),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(selected ? (contrast == .increased ? 0.8 : 0.30) : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? tab.id : (hoveredID == tab.id ? nil : hoveredID) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: selected)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue("\(selected ? "Selected, " : "")\(tab.currentURL.host ?? tab.currentURL.scheme ?? "Page")")
        .accessibilityHint("Switch to this tab")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tabSwitcher.tab.\(tab.id)")
        .help(tab.displayTitle)
    }
}

/// Event classification is separately testable without posting keyboard events.
enum TabSwitcherKeyRouting {
    enum Action: Equatable { case advance(Int), commit, cancel, cancelAndPass, pass }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, presented: Bool) -> Action {
        // Leave VoiceOver's Control-Option navigation to the accessibility
        // system, including while its user is exploring the preview cards.
        if modifiers.contains([.control, .option]) { return .pass }
        guard modifiers.intersection([.command, .option]).isEmpty else {
            return presented ? .cancelAndPass : .pass
        }
        if keyCode == 48, modifiers.contains(.control) || presented {
            return .advance(modifiers.contains(.shift) ? -1 : 1)
        }
        guard presented else { return .pass }
        switch keyCode {
        case 123: return .advance(-1)
        case 124: return .advance(1)
        case 36, 76: return .commit
        case 53: return .cancel
        default: return .cancelAndPass
        }
    }
}

/// One monitor per owning window. It never replaces the web view's responder or
/// handles keys in Settings/another profile/window. No global keyboard monitor.
struct TabSwitcherKeyboardMonitor: NSViewRepresentable {
    let model: BrowserWindowModel
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        weak var model: BrowserWindowModel?
        private var monitor: Any?
        private var suppressedKeyUps: Set<UInt16> = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: NSApplication.didResignActiveNotification, object: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self)
            suppressedKeyUps.removeAll()
        }

        @objc private func cancel() {
            suppressedKeyUps.removeAll()
            model?.cancelTabSwitcher(restoreFocus: false)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, window.isKeyWindow, let model,
                  event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return event }
            if event.type == .keyUp {
                return suppressedKeyUps.remove(event.keyCode) != nil ? nil : event
            }
            guard window.attachedSheet == nil,
                  (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
                model.cancelTabSwitcher(restoreFocus: false)
                return event
            }
            if event.type == .flagsChanged {
                if model.tabSwitcherCommitsOnControlRelease && !event.modifierFlags.contains(.control) {
                    model.commitTabSwitcher()
                }
                return event
            }
            let route = TabSwitcherKeyRouting.action(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                     presented: model.tabSwitcher != nil)
            switch route {
            case .advance(let delta):
                guard model.advanceTabSwitcher(delta, commitsOnControlRelease: event.modifierFlags.contains(.control)) else { return event }
            case .commit: model.commitTabSwitcher()
            case .cancel: model.cancelTabSwitcher()
            case .cancelAndPass:
                model.cancelTabSwitcher(restoreFocus: false)
                return event
            case .pass: return event
            }
            suppressedKeyUps.insert(event.keyCode)
            return nil
        }
    }
}

/// Outside clicks cancel without stealing focus from that click's destination.
private struct TabSwitcherCardBoundary: NSViewRepresentable {
    let model: BrowserWindowModel
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stop() }

    final class BoundaryView: NSView {
        weak var model: BrowserWindowModel?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, self.model?.tabSwitcher != nil else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.model?.cancelTabSwitcher(restoreFocus: false)
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
