// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Stable tab-keyed hosts survive single/split transitions and divider changes.
/// A drag preview changes geometry only; its candidate is cache/metadata-only.
struct SplitContentView: View {
    @Bindable var model: BrowserWindowModel
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
                    let hidden = model.splitPreview.map { !$0.tabIDs.contains(id) } ?? false
                    let paneID = group?.panes.first { $0.tabID == id }?.id
                    pane(id, paneID: paneID, split: group != nil || model.splitPreview != nil)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(hidden ? 0 : 1)
                        .allowsHitTesting(!hidden && model.splitPreview == nil)
                        .accessibilityHidden(hidden)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.splitPreview)
                }
                if let group, model.splitPreview == nil {
                    SplitDivider(model: model, group: group, layout: layout)
                        .frame(width: layout.divider.width, height: layout.divider.height)
                        .position(x: layout.divider.midX, y: layout.divider.midY)
                }
                if let preview = model.splitPreview {
                    let previewLayout = BrowserSplitLayout(size: geometry.size, leadingFraction: preview.leadingFraction)
                    let index = preview.reusesExistingPane
                        ? (preview.tabIDs.firstIndex(of: preview.sourceTabID) ?? preview.side.index) : preview.side.index
                    let frame = previewLayout.frame(at: index)
                    splitPreview(preview)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "splitContent")
        }
    }

    private func frame(for id: UUID, size: CGSize, layout: BrowserSplitLayout) -> CGRect {
        if let preview = model.splitPreview, let index = preview.tabIDs.firstIndex(of: id) {
            return BrowserSplitLayout(size: size, leadingFraction: preview.leadingFraction).frame(at: index)
        }
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
                    && model.splitPreview == nil && !model.hasVisibleDialog,
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

    private func splitPreview(_ proposal: BrowserSplitPlacement) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(proposal.reusesExistingPane ? 0.08 : 0.12))
            if !proposal.reusesExistingPane {
                VStack(spacing: 12) {
                    if let image = model.webViews.snapshots.image(for: proposal.sourceTabID) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 150).clipped()
                    }
                    Image(systemName: "rectangle.split.2x1").font(.title2)
                    Text(model.coordinator.tabStore.tab(id: proposal.sourceTabID)?.displayTitle ?? "Tab")
                        .font(.headline).lineLimit(1)
                    Text("Release to split \(proposal.side == .leading ? "left" : "right")").font(.callout)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
        }
        .accessibilityIdentifier("split.dropPreview")
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
