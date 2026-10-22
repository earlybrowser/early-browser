// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// A page has one rounded edge. Split panes own it individually; their shared
/// container must not draw or round a second border across the pair.
struct BrowserContentSurface: ViewModifier {
    enum Border: Equatable { case none, standard, focused }
    let cornerRadius: CGFloat
    let border: Border
    let theme: BrowserSpace.Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static func container(cornerRadius: CGFloat, split: Bool) -> Self {
        Self(cornerRadius: split ? 0 : cornerRadius, border: split ? .none : .standard, theme: .gray)
    }

    static func pane(cornerRadius: CGFloat, split: Bool, focused: Bool, theme: BrowserSpace.Color = .gray) -> Self {
        Self(cornerRadius: split ? cornerRadius : 0, border: split ? (focused ? .focused : .standard) : .none, theme: theme)
    }

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }
    var borderWidth: CGFloat {
        switch border {
        case .none: 0
        case .standard: 1
        case .focused: 2
        }
    }

    private var borderColor: Color {
        border == .focused
            ? theme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
            : Color.primary.opacity(contrast == .increased ? 0.30 : 0.08)
    }

    func body(content: Content) -> some View {
        content.clipShape(shape)
            .overlay {
                if border != .none {
                    // The focused theme edge thickens inward. Both strokes
                    // share the clipping edge, without a second inset ring.
                    shape.strokeBorder(borderColor, lineWidth: borderWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Stable tab-keyed hosts survive single/split transitions and divider changes.
/// Drag targets are overlays only: hover NEVER resizes or hides a live page.
struct SplitContentView: View {
    @Bindable var model: BrowserWindowModel
    var dropTargetLeadingInset: CGFloat = 0
    var contentCornerRadius: CGFloat = 8
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
                    SplitDivider(model: model, group: group, layout: layout,
                        enabled: model.splitResize?.groupID == group.id || model.canPerform(.resizeSplit(group.id, layout.fraction)),
                        resizing: model.splitResize?.groupID == group.id)
                        // An invisible full-height hit area; only keyboard focus
                        // draws a cue, without restoring pointer decorations.
                        .frame(width: min(12, geometry.size.width), height: layout.divider.height)
                        .position(x: layout.divider.midX, y: layout.divider.midY)
                        .allowsHitTesting(model.splitDropSourceID == nil)
                        // Native input must sit above newly inserted WebKit
                        // hosts and must not inherit their insertion fade.
                        .zIndex(1)
                        .transition(.identity)
                }
            }
            // Space handoffs get a fast-starting opacity transition, including between
            // two ordinary (non-split) pages. Keep tab-keyed hosts so a shared
            // Favorite never gets rehosted merely because its Space changed.
            .animation(reduceMotion ? nil : .easeOut(duration: SpaceSwitchMotion.contentDuration), value: model.coordinator.activeSpaceID)
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
            // Match the actual page, not the browser appearance: a dark site
            // in light chrome must not flash a white island during attachment.
            Color(nsColor: page?.view.underPageBackgroundColor ?? .textBackgroundColor)
            WebContentView(view: page?.view, focusRequest: model.contentFocusRequest,
                canFocus: focused && model.coordinator.commandBar == nil && model.tabSwitcher == nil
                    && model.splitDropSourceID == nil && !model.hasVisibleDialog,
                hasDialog: page?.hasDialog == true,
                isResizing: model.splitResize != nil,
                onInteraction: {
                    if model.coordinator.commandBar != nil { model.dismissCommandBar(restoreFocus: false) }
                    if let paneID { _ = model.focusPane(paneID, restoreFocus: false) }
                },
                onPress: { model.recordPagePress(at: $0) })
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
        .modifier(BrowserContentSurface.pane(cornerRadius: contentCornerRadius, split: split, focused: focused,
                                            theme: model.splitTheme))
        .overlay(alignment: page?.hoveredLink?.avoidsLeadingCorner == true ? .bottomTrailing : .bottomLeading) {
            if let hover = page?.hoveredLink, page?.isFullscreen != true {
                LinkPreview(hover: hover, theme: model.splitTheme, allowsTransparency: model.preferences.translucentChrome)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Clear of the split pane's remove button in the same corner.
            PageToolsOverlay(model: model, tabID: id)
                .padding(.top, 10)
                .padding(.trailing, paneID == nil ? 10 : 40)
        }
        .overlay(alignment: .topTrailing) {
            if let paneID, hoveredTabID == id || page?.failure != nil {
                Button { _ = model.perform(.removeSplitPane(paneID)) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus(cornerRadius: 6)
                .padding(6)
                .disabled(!model.canPerform(.removeSplitPane(paneID)))
                .accessibilityLabel("Remove pane from split; keep tab open")
                .accessibilityIdentifier("split.remove.\(paneID)")
                .help("Remove from split (keeps both tabs open)")
            }
        }
        .onHover { hoveredTabID = $0 ? id : (hoveredTabID == id ? nil : hoveredTabID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(split ? "\(focused ? "Focused p" : "P")ane: \(model.coordinator.tabStore.tab(id: id)?.displayTitle ?? "Page")" : "Web content")
        .accessibilityActions {
            if let paneID, let group = model.coordinator.activeSplitGroup {
                if !focused {
                    Button("Focus Pane") { _ = model.perform(.focusSplitPane(paneID)) }
                }
                Button("Remove Pane; Keep Tab Open") { _ = model.perform(.removeSplitPane(paneID)) }
                Button("Swap Sides") { _ = model.perform(.swapSplit(group.id)) }
                Button("Exit Split View") { _ = model.perform(.exitSplit(group.id)) }
            }
        }
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
                SplitDropCard(theme: model.splitTheme, side: side, highlighted: highlighted,
                    title: reuses ? "Focus existing pane" : "\(model.coordinator.activeSplitGroup == nil ? "Add" : "Replace") \(name) split",
                    size: frame.size, allowsTransparency: model.preferences.translucentChrome)
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

/// Both borders keep the same radius. Padding the dashed shape (rather than
/// insetting its path) avoids subtracting the inset from its corner radius.
struct SplitDropCard: View {
    static let cornerRadius: CGFloat = 18
    static let borderInset: CGFloat = 9
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    let theme: BrowserSpace.Color
    let side: BrowserSplitSide
    let highlighted: Bool
    let title: String
    let size: CGSize
    let allowsTransparency: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            BrowserChromeBackground(spaceColor: theme, floating: true, allowsTransparency: allowsTransparency)
                .clipShape(Self.shape)
            Self.shape.fill(theme.tint.opacity(highlighted ? 0.16 : 0.06))
            Self.shape.strokeBorder(theme.tint.opacity(contrast == .increased ? 0.8 : (highlighted ? 0.5 : 0.25)), lineWidth: 1)
            Self.shape
                .strokeBorder(theme.tint.opacity(contrast == .increased || highlighted ? 1 : 0.55),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 6]))
                .padding(Self.borderInset)
            VStack(spacing: size.height < 180 ? 8 : 12) {
                Image(systemName: side == .leading ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                    .font(size.width < 130 ? .title3 : .title2)
                Text(title).font(size.width < 130 ? .callout : .headline).multilineTextAlignment(.center)
            }
            .foregroundStyle(highlighted ? Color.primary : Color.secondary)
            .padding(size.width < 130 ? 10 : 18)
        }
    }
}

struct SplitDivider: NSViewRepresentable {
    @Bindable var model: BrowserWindowModel
    let group: BrowserSplitGroup
    let layout: BrowserSplitLayout
    // Read in the SwiftUI body, not only inside updateNSView. Finishing a
    // sidebar drag must invalidate this native bridge even if layout is equal.
    let enabled: Bool
    let resizing: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> SplitDividerView { SplitDividerView() }
    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.canInteract = {
            model.splitResize?.groupID == group.id || model.canPerform(.resizeSplit(group.id, layout.fraction))
        }
        view.onBegin = {
            model.beginSplitResize(group.id)
            return model.splitResize?.groupID == group.id
        }
        view.onResize = { model.updateSplitResize($0) }
        view.onEnd = { model.finishSplitResize(commit: $0) }
        view.onAdjust = { amount in
            let saved = model.coordinator.activeSplitGroup?.leadingFraction ?? layout.fraction
            let current = min(max(saved, layout.fractionRange.lowerBound), layout.fractionRange.upperBound)
            let next = min(max(current + amount, layout.fractionRange.lowerBound), layout.fractionRange.upperBound)
            return model.perform(.resizeSplit(group.id, next))
        }
        view.configure(groupID: group.id, layout: layout,
            enabled: enabled, resizing: resizing, increasedContrast: contrast == .increased)
    }
    static func dismantleNSView(_ view: SplitDividerView, coordinator: ()) { view.invalidate() }
}

/// Owns the small native hit/cursor region, rather than racing WebKit's cursor
/// with SwiftUI onHover. No event monitor, tracking loop or global cursor change.
final class SplitDividerView: NSView {
    var canInteract: (() -> Bool)?
    var onBegin: (() -> Bool)?
    var onResize: ((Double) -> Void)?
    var onEnd: ((Bool) -> Void)?
    var onAdjust: ((Double) -> Bool)?
    private var groupID: UUID?
    private var fraction = 0.5
    private var fractionRange = 0.2...0.8
    private var usableWidth: CGFloat = 0
    private var enabled = false
    private var increasedContrast = false
    private var tracking: NSTrackingArea?
    private var dragAnchor: (x: CGFloat, fraction: Double)?
    private var takingPointerFocus = false
    private(set) var keyboardFocused = false
    private var invalidated = false
    private(set) var resizeCursorRect: CGRect?

    /// Native events can arrive before SwiftUI delivers a render update. Read
    /// the current window gate instead of trusting the last disabled snapshot.
    private var isInteractive: Bool { !invalidated && (canInteract?() ?? enabled) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { return nil }

    func configure(groupID: UUID, layout: BrowserSplitLayout, enabled: Bool, resizing: Bool, increasedContrast: Bool) {
        guard !invalidated else { return }
        if self.groupID != groupID || !resizing { dragAnchor = nil }
        self.groupID = groupID
        let fractionChanged = fraction != layout.fraction
        fraction = layout.fraction
        fractionRange = layout.fractionRange
        usableWidth = layout.leading.width + layout.trailing.width
        self.enabled = enabled
        self.increasedContrast = increasedContrast
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        if fractionChanged, window != nil { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let region = bounds.intersection(visibleRect)
        resizeCursorRect = isInteractive && !region.isEmpty ? region : nil
        if let resizeCursorRect { addCursorRect(resizeCursorRect, cursor: .resizeLeftRight) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !invalidated else { return }
        // updateNSView/attachment may run while the representable is still
        // zero-sized. AppKit must follow its clipped visible bounds after the
        // first layout, rather than freezing that initial empty rectangle.
        tracking = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        if let tracking { addTrackingArea(tracking) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !invalidated else { return }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }
    override func layout() {
        super.layout()
        guard !invalidated else { return }
        // Configuration precedes frame assignment. Register the cursor again
        // once its actual native hit area is known, without a swap/reconfigure.
        window?.invalidateCursorRects(for: self)
    }
    override func cursorUpdate(with event: NSEvent) { if isInteractive { NSCursor.resizeLeftRight.set() } }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endResize(commit: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Keep a clean gap at rest, on hover and during pointer resizing. The
        // full native hit area/cursor remain; only keyboard focus draws a cue.
        guard isInteractive, keyboardFocused else { return }
        let height = min(48.0, max(0, bounds.height - 16))
        NSColor.labelColor.withAlphaComponent(increasedContrast ? 0.85 : 0.55).setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.midX - 2, y: bounds.midY - height / 2,
            width: 4, height: height), xRadius: 2, yRadius: 2).fill()
    }

    override var acceptsFirstResponder: Bool { isInteractive }
    override func becomeFirstResponder() -> Bool {
        guard isInteractive else { return false }
        keyboardFocused = !takingPointerFocus
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool { keyboardFocused = false; needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        keyboardFocused = false
        takingPointerFocus = true
        window?.makeFirstResponder(self)
        takingPointerFocus = false
        beginResize(atWindowX: event.locationInWindow.x)
    }
    override func mouseDragged(with event: NSEvent) {
        updateResize(atWindowX: event.locationInWindow.x)
    }
    override func mouseUp(with event: NSEvent) {
        updateResize(atWindowX: event.locationInWindow.x)
        endResize(commit: true)
        // Leave cursor restoration to AppKit's native cursor rectangles, not a
        // forced arrow that would override the adjacent webpage's text cursor.
        window?.invalidateCursorRects(for: self)
    }

    func beginResize(atWindowX x: CGFloat) {
        guard isInteractive, x.isFinite, usableWidth > 0, dragAnchor == nil, onBegin?() == true else { return }
        dragAnchor = (x, fraction)
        needsDisplay = true
    }
    func updateResize(atWindowX x: CGFloat) {
        guard let anchor = dragAnchor, x.isFinite, usableWidth > 0 else { return }
        onResize?(min(max(anchor.fraction + (x - anchor.x) / usableWidth, fractionRange.lowerBound), fractionRange.upperBound))
    }
    func endResize(commit: Bool) {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        onEnd?(commit)
        needsDisplay = true
    }

    static func adjustment(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Double? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        return keyCode == 123 ? -0.05 : (keyCode == 124 ? 0.05 : nil)
    }
    override func keyDown(with event: NSEvent) {
        if isInteractive, let amount = Self.adjustment(for: event.keyCode, modifiers: event.modifierFlags) {
            keyboardFocused = true
            _ = onAdjust?(amount)
            needsDisplay = true
        } else if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Split divider" }
    override func accessibilityIdentifier() -> String { "split.divider" }
    override func accessibilityValue() -> Any? { "\(Int(fraction * 100)) percent left pane" }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
    override func isAccessibilityEnabled() -> Bool { isInteractive }
    override func accessibilityPerformIncrement() -> Bool { isInteractive && onAdjust?(0.05) == true }
    override func accessibilityPerformDecrement() -> Bool { isInteractive && onAdjust?(-0.05) == true }

    func invalidate() {
        invalidated = true
        endResize(commit: false)
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        discardCursorRects()
        resizeCursorRect = nil
        enabled = false
        canInteract = nil
        onBegin = nil; onResize = nil; onEnd = nil; onAdjust = nil
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
