// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Stable tab-keyed hosts survive single/split transitions and divider changes.
/// Drag targets are overlays only: hover NEVER resizes or hides a live page.
struct SplitContentView: View {
    @Bindable var model: BrowserWindowModel
    var dropTargetLeadingInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredTabID: UUID?

    private var tabIDs: [UUID] {
        model.coordinator.activeSplitGroup?.panes.map(\.tabID) ?? model.coordinator.focusedTabID.map { [$0] } ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            let group = model.coordinator.activeSplitGroup
            let fraction = model.splitResize?.fraction ?? group?.leadingFraction ?? 0.5
            let layout = BrowserSplitLayout(size: geometry.size, leadingFraction: fraction)
            ZStack(alignment: .topLeading) {
                if tabIDs.isEmpty {
                    if reduceTransparency || contrast == .increased { Color(nsColor: .windowBackgroundColor) }
                    else { Color.white.opacity(colorScheme == .dark ? 0.01 : 0.08) }
                }
                ForEach(tabIDs, id: \.self) { id in
                    let frame = frame(for: id, size: geometry.size, layout: layout)
                    let paneID = group?.panes.first { $0.tabID == id }?.id
                    pane(id, paneID: paneID, split: group != nil)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(model.splitDropSourceID == nil)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                if let group {
                    SplitDivider(model: model, group: group, layout: layout)
                        .frame(width: layout.divider.width, height: layout.divider.height)
                        .position(x: layout.divider.midX, y: layout.divider.midY)
                        .allowsHitTesting(model.splitDropSourceID == nil)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            // Animate only COMMITTED membership changes, not pointer movement,
            // focus, window resizing or live divider tracking. A surviving host
            // expands/contracts in place while the added/removed pane fades.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: group?.panes.map(\.tabID))
            .overlay {
                if let sourceID = model.splitDropSourceID,
                   let targets = BrowserSplitDropTargets(in: CGRect(origin: .zero, size: geometry.size), leadingInset: dropTargetLeadingInset) {
                    splitDropTargets(targets, sourceID: sourceID)
                        .transition(reduceMotion ? .identity : .opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.splitDropSourceID != nil)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "splitContent")
        }
    }

    private func frame(for id: UUID, size: CGSize, layout: BrowserSplitLayout) -> CGRect {
        if model.coordinator.activeSplitGroup != nil, let index = tabIDs.firstIndex(of: id) { return layout.frame(at: index) }
        return CGRect(origin: .zero, size: size)
    }

    private func pane(_ id: UUID, paneID: UUID?, split: Bool) -> some View {
        let page = model.webViews.pages[id]
        let focused = model.coordinator.focusedTabID == id
        return ZStack {
            Color(nsColor: .textBackgroundColor)
            WebContentView(view: page?.view, focusRequest: model.contentFocusRequest,
                canFocus: focused && model.coordinator.commandBar == nil && model.tabSwitcher == nil
                    && model.splitDropSourceID == nil && !model.hasVisibleDialog,
                hasDialog: page?.hasDialog == true,
                onInteraction: {
                    if model.coordinator.commandBar != nil { model.dismissCommandBar(restoreFocus: false) }
                    if let paneID { _ = model.focusPane(paneID, restoreFocus: false) }
                })
                .accessibilityIdentifier("browser.pane.\(id)")
            if let error = page?.failure {
                VStack(spacing: 12) {
                    Label("Unable to open this page", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).multilineTextAlignment(.center)
                    Button("Try Again") {
                        if let paneID { _ = model.focusPane(paneID) }
                        _ = model.perform(.reload)
                    }
                    .accessibilityIdentifier("browser.retry")
                }
                .padding(24).frame(maxWidth: 440)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("browser.error")
            }
        }
        .overlay(alignment: .topLeading) {
            if let page, page.isLoading {
                GeometryReader { geometry in
                    Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * min(max(page.progress, 0), 1))
                }
                .frame(height: 2).allowsHitTesting(false)
                .accessibilityLabel("Page loading")
                .accessibilityValue("\(Int(min(max(page.progress, 0), 1) * 100)) percent")
                .accessibilityIdentifier("browser.loading")
            }
        }
        .overlay(alignment: .top) {
            if let notice = page?.navigationNotice {
                HStack(spacing: 10) {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { model.webViews.dismissNavigationNotice(for: id) }
                }
                .font(.callout).padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(10)
                .accessibilityIdentifier("browser.navigationNotice.\(id)")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: split ? 8 : 0))
        .overlay {
            if split {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(focused ? (contrast == .increased ? 0.65 : 0.27) : 0.07), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let paneID, hoveredTabID == id || page?.failure != nil {
                Button { _ = model.perform(.removeSplitPane(paneID)) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).padding(6)
                .disabled(!model.canPerform(.removeSplitPane(paneID)))
                .accessibilityLabel("Remove pane from split; keep tab open")
                .accessibilityIdentifier("split.remove.\(paneID)")
                .help("Remove from split (keeps both tabs open)")
            }
        }
        .onHover { hoveredTabID = $0 ? id : (hoveredTabID == id ? nil : hoveredTabID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(split ? "\(focused ? "Focused p" : "P")ane: \(model.coordinator.tabStore.tab(id: id)?.displayTitle ?? "Page")" : "Web content")
    }

    private func splitDropTargets(_ targets: BrowserSplitDropTargets, sourceID: UUID) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12)
            ForEach(BrowserSplitSide.allCases, id: \.self) { side in
                let frame = targets.frame(on: side)
                let highlighted = model.splitPreview?.side == side
                let proposal = model.coordinator.splitPlacement(for: sourceID, on: side)
                let reuses = proposal?.reusesExistingPane == true
                let name = side == .leading ? "left" : "right"
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(reduceTransparency || contrast == .increased ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.accentColor.opacity(highlighted ? 0.13 : 0))
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.10), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 12).inset(by: 9)
                        .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(contrast == .increased ? 0.6 : 0.24),
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    VStack(spacing: frame.height < 180 ? 8 : 12) {
                        Image(systemName: side == .leading ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                            .font(frame.width < 130 ? .title3 : .title2)
                        Text(reuses ? "Focus existing pane" : "\(model.coordinator.activeSplitGroup == nil ? "Add" : "Replace") \(name) split")
                            .font(frame.width < 130 ? .callout : .headline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(highlighted ? Color.primary : Color.secondary)
                    .padding(frame.width < 130 ? 10 : 18)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 12, y: 4)
                // A highlight never scales the card: its visible/hit bounds agree.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: highlighted)
                .accessibilityIdentifier("split.dropTarget.\(side.rawValue)")
            }
        }
        .accessibilityIdentifier("split.dropTargets")
    }
}

private struct SplitDivider: View {
    @Bindable var model: BrowserWindowModel
    let group: BrowserSplitGroup
    let layout: BrowserSplitLayout
    @State private var startFraction: Double?
    @GestureState private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        Rectangle().fill(Color.primary.opacity(focused || dragging ? 0.25 : 0.08))
            .contentShape(Rectangle())
            .onHover { ($0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("splitContent"))
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    if startFraction == nil {
                        startFraction = layout.fraction
                        model.beginSplitResize(group.id)
                    }
                    let usable = layout.leading.width + layout.trailing.width
                    guard usable > 0 else { return }
                    let next = (startFraction ?? layout.fraction) + value.translation.width / usable
                    model.updateSplitResize(min(max(next, layout.fractionRange.lowerBound), layout.fractionRange.upperBound))
                }
                .onEnded { _ in
                    startFraction = nil
                    model.finishSplitResize(commit: true)
                    NSCursor.arrow.set()
                })
            .focusable().focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                adjust(press.key == .leftArrow ? -0.05 : 0.05)
                return .handled
            }
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int(layout.fraction * 100)) percent left pane")
            .accessibilityIdentifier("split.divider")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(0.05)
                case .decrement: adjust(-0.05)
                @unknown default: break
                }
            }
            .onChange(of: dragging) { _, active in
                if !active {
                    Task { @MainActor in
                        await Task.yield()
                        if !dragging { startFraction = nil; model.finishSplitResize(commit: false) }
                    }
                }
            }
            .onDisappear { model.finishSplitResize(commit: false) }
    }

    private func adjust(_ amount: Double) {
        let next = min(max(layout.fraction + amount, layout.fractionRange.lowerBound), layout.fractionRange.upperBound)
        _ = model.perform(.resizeSplit(group.id, next))
    }
}

/// Cancel transient geometry on window/sheet/Space transitions. Never replace
/// the owning NSWindow delegate or install a global keyboard hook.
struct BrowserWindowActivityMonitor: NSViewRepresentable {
    let onCancel: () -> Void
    let isInteracting: Bool
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.onCancel = onCancel
        view.isInteracting = isInteracting
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onCancel: (() -> Void)?
        var isInteracting = false
        private var keys: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification,
                         NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: NSApplication.didResignActiveNotification, object: nil)
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isInteracting, event.keyCode == 53,
                      event.window === self.window, self.window?.attachedSheet == nil else { return event }
                self.cancel()
                return nil
            }
        }
        @objc func cancel() { onCancel?() }
        func stop() {
            NotificationCenter.default.removeObserver(self)
            if let keys { NSEvent.removeMonitor(keys) }
            keys = nil
        }
    }
}
