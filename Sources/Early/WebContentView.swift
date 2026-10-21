// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI
import WebKit

/// Wallpaper-aware chrome only. Loaded websites retain their normal opaque
/// background and are never tinted or rendered through a transparency layer.
struct BrowserChromeBackground: View {
    var spaceColor: BrowserSpace.Color = .gray
    var floating = false
    var allowsTransparency = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else {
                if !reduceTransparency && allowsTransparency { ChromeMaterial(floating: floating) }
                if colorScheme == .dark, !reduceTransparency && allowsTransparency { Color.black.opacity(0.30) }
                LinearGradient(colors: [spaceColor.chromeTop(isDark: colorScheme == .dark).color,
                                        spaceColor.chromeBottom(isDark: colorScheme == .dark).color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(reduceTransparency || !allowsTransparency ? 1 : (colorScheme == .dark ? 0.64 : 0.68))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: spaceColor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: colorScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct ChromeMaterial: NSViewRepresentable {
        let floating: Bool
        func makeNSView(context: Context) -> MaterialView {
            let view = MaterialView()
            view.material = floating ? .popover : .sidebar
            view.blendingMode = floating ? .withinWindow : .behindWindow
            view.state = .followsWindowActiveState
            return view
        }
        func updateNSView(_ view: MaterialView, context: Context) {}

        final class MaterialView: NSVisualEffectView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func isAccessibilityElement() -> Bool { false }
        }
    }
}

#if DEBUG
/// A window-scoped, non-drawing probe. Keeping it outside the sidebar lets UI
/// tests verify lazy-page counts while the actual sidebar stays hidden.
struct TestRuntimeState: NSViewRepresentable {
    let value: String

    func makeNSView(context: Context) -> StateView { StateView() }

    func updateNSView(_ view: StateView, context: Context) {
        guard view.runtime != value else { return }
        view.runtime = value
        if view.window != nil { NSAccessibility.post(element: view, notification: .valueChanged) }
    }

    final class StateView: NSView {
        var runtime = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityIdentifier() -> String { "test.runtime" }
        override func accessibilityValue() -> Any? { runtime }
    }
}

/// Read-only test seam: fullscreen state must not be inferred from window width
/// (a maximized window can have the same width). Not installed in normal runs.
struct TestWindowState: NSViewRepresentable {
    func makeNSView(context: Context) -> StateView { StateView() }
    func updateNSView(_ view: StateView, context: Context) {}

    final class StateView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityIdentifier() -> String { "test.windowState" }
        override func accessibilityValue() -> Any? {
            guard let window else { return "detached" }
            let controls = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            let sizes = controls.compactMap { window.standardWindowButton($0)?.frame.size }
            let fullscreen = window.styleMask.contains(.fullScreen)
            let nativeSize = sizes.count == 3 && sizes.allSatisfy { $0 == NSSize(width: 14, height: 14) }
            let details = controls.compactMap { kind -> String? in
                guard let button = window.standardWindowButton(kind) else { return "missing" }
                return "\(button.superview?.className ?? "nil") hidden=\(button.isHiddenOrHasHiddenAncestor) window=\(button.window === window) frame=\(button.frame)"
            }.joined(separator: "; ")
            return "\(fullscreen ? "fullscreen" : "windowed") · nativeSize \(nativeSize) · \(details)"
        }
    }
}
#endif

/// Keep the real AppKit controls for native glass rendering and window actions.
/// A mouse-transparent overlay draws neutral circles only at rest. AppKit draws
/// the glass and hover glyphs; each window has exactly one owning control host.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsHost { ControlsHost() }
    func updateNSView(_ view: ControlsHost, context: Context) { view.synchronize() }
    static func dismantleNSView(_ view: ControlsHost, coordinator: ()) { view.detach() }

    private final class ControlsContainer: NSView {
        private let idleDrawingMask = CALayer()

        func updateDrawingMask() {
            guard let layer else { return }
            // Native window widgets can draw outside the ordinary NSButtonCell
            // transparency path. Mask their composited drawing instead. Do not
            // hide the NSViews or change alphaValue: keep native hit testing,
            // accessibility, enabled state, and window actions intact.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            idleDrawingMask.frame = layer.bounds
            idleDrawingMask.backgroundColor = NSColor.clear.cgColor
            layer.mask = mouseInside ? nil : idleDrawingMask
            CATransaction.commit()
        }

        var mouseInside = false {
            didSet {
                guard oldValue != mouseInside else { return }
                refreshButtonAppearance()
            }
        }

        func refreshButtonAppearance() {
            // Refresh the cells as a group, not just the view under the cursor.
            // AppKit can invalidate individual widget cells after our tracking
            // callback, while the group's mouseInside value remains unchanged.
            for case let button as NSButton in subviews {
                // Reparented widgets no longer receive NSTitlebarView's group
                // rollover invalidation. Ask the native widget to recompute its
                // own rollover state, including its glass glyph, before drawing.
                let rollover = NSSelectorFromString("mouseEnteredOrExited")
                if button.responds(to: rollover) { button.perform(rollover) }
                if let cell = button.cell { button.updateCell(cell) }
                button.needsDisplay = true
            }
        }

        // AppKit's native titlebar widgets query their immediate parent for
        // group rollover. Supply it locally instead of drawing replacement
        // glyphs or swizzling the widget cells. This is an undocumented AppKit
        // compatibility seam and needs coverage on each supported macOS version.
        @objc(_mouseInGroup:)
        func mouseInGroup(_ button: NSButton) -> Bool {
            mouseInside && button.superview === self && button.isEnabled
        }

        static var isPositioningButtons = false
        private static let swizzleOnce: Void = {
            guard let widgetClass = NSClassFromString("_NSThemeWidget") else { return }

            let sel1 = #selector(NSView.setFrameOrigin(_:))
            if let m1 = class_getInstanceMethod(widgetClass, sel1) {
                typealias SetOriginIMP = @convention(c) (AnyObject, Selector, NSPoint) -> Void
                let origIMP = unsafeBitCast(method_getImplementation(m1), to: SetOriginIMP.self)
                let block1: @convention(block) (NSView, NSPoint) -> Void = { view, pt in
                    if view.superview is ControlsContainer && !ControlsContainer.isPositioningButtons {
                        return
                    }
                    origIMP(view, sel1, pt)
                }
                // Install on the widget class itself, even if a future AppKit
                // version inherits this method. Never replace NSView's method.
                class_replaceMethod(widgetClass, sel1, imp_implementationWithBlock(block1), method_getTypeEncoding(m1))
            }

            let sel2 = NSSelectorFromString("setFrameOrigin:ignoreRentry:")
            if let m2 = class_getInstanceMethod(widgetClass, sel2) {
                typealias SetOriginIgnoreIMP = @convention(c) (AnyObject, Selector, NSPoint, Bool) -> Void
                let origIMP = unsafeBitCast(method_getImplementation(m2), to: SetOriginIgnoreIMP.self)
                let block2: @convention(block) (NSView, NSPoint, Bool) -> Void = { view, pt, ignore in
                    if view.superview is ControlsContainer && !ControlsContainer.isPositioningButtons {
                        return
                    }
                    origIMP(view, sel2, pt, ignore)
                }
                class_replaceMethod(widgetClass, sel2, imp_implementationWithBlock(block2), method_getTypeEncoding(m2))
            }

            // In full-screen mode, AppKit generates an internal NSTitlebarBackgroundView
            // under the slide-down menu bar. Setting its layer opacity to 0 removes the grey
            // titlebar box completely without modifying window hierarchy or space transitions.
            if let bgClass = NSClassFromString("NSTitlebarBackgroundView") {
                let updateLayerSel = NSSelectorFromString("updateLayer")
                if let mUpdateLayer = class_getInstanceMethod(bgClass, updateLayerSel) {
                    typealias UpdateLayerIMP = @convention(c) (AnyObject, Selector) -> Void
                    let origUpdateLayer = unsafeBitCast(method_getImplementation(mUpdateLayer), to: UpdateLayerIMP.self)
                    let blockUpdateLayer: @convention(block) (NSView) -> Void = { view in
                        origUpdateLayer(view, updateLayerSel)
                        // This existing compatibility hook must never alter
                        // Settings, website sheets, or another app window.
                        guard ControlsHost.ownsControls(in: view.window) else { return }
                        view.layer?.opacity = view.window?.styleMask.contains(.fullScreen) == true ? 0 : 1
                    }
                    class_replaceMethod(bgClass, updateLayerSel, imp_implementationWithBlock(blockUpdateLayer), method_getTypeEncoding(mUpdateLayer))
                }
            }
        }()

        override init(frame: NSRect) {
            Self.swizzleOnce
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            Self.swizzleOnce
            super.init(coder: coder)
        }
    }

    final class ControlsHost: NSView {
        // Weak on both sides: this registry must not keep windows or SwiftUI
        // representables alive. Only viewDidMoveToWindow may claim ownership;
        // updates/notifications from a superseded host cannot steal it back.
        private static let owners = NSMapTable<NSWindow, ControlsHost>.weakToWeakObjects()

        static func ownsControls(in window: NSWindow?) -> Bool {
            var current = window
            for _ in 0..<4 {
                guard let candidate = current else { return false }
                if owners.object(forKey: candidate) != nil { return true }
                current = candidate.parent
            }
            return false
        }

        private struct NativeControl {
            let kind: NSWindow.ButtonType
            let button: NSButton
            weak var parent: NSView?
            let frame: NSRect
            let wasHidden: Bool
            let postedFrameChanges: Bool
        }
        private struct TitlebarVisibility {
            weak var view: NSView?
            let wasHidden: Bool
        }
        private var nativeControls: [NativeControl] = []
        private var titlebarVisibility: [TitlebarVisibility] = []
        private weak var attachedWindow: NSWindow?
        private var sheetIsPresenting = false
        private var reconciliationScheduled = false
        private var hoverRefreshScheduled = false
        private let nativeContainer = ControlsContainer()
        private let appearanceOverlay = AppearanceOverlay()
        private var hoverTrackingArea: NSTrackingArea?

        private var ownsControls: Bool {
            guard let attachedWindow else { return false }
            return Self.owners.object(forKey: attachedWindow) === self
        }

        private final class AppearanceOverlay: NSView {
            var buttonFrames: [(kind: NSWindow.ButtonType, frame: NSRect)] = [] { didSet { needsDisplay = true } }
            var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func isAccessibilityElement() -> Bool { false }
            override var isOpaque: Bool { false }
            override func draw(_ dirtyRect: NSRect) {
                if hovered {
                    // When hovered, let macOS's built-in buttons render their own
                    // native icons without any custom vector drawings on top.
                    return
                }
                let isFullScreen = window?.styleMask.contains(.fullScreen) == true
                let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                for (kind, frame) in buttonFrames {
                    // Native button drawing is masked while idle. Blend a
                    // neutral circle directly into the chrome,
                    // with no opaque backing, outline, or shadow-covering rim.
                    let circle = NSBezierPath(ovalIn: frame)
                    let alpha: CGFloat = (kind == .miniaturizeButton && isFullScreen)
                        ? (highContrast ? 0.12 : 0.06)
                        : (highContrast ? 0.25 : 0.12)
                    NSColor.labelColor.withAlphaComponent(alpha).setFill()
                    circle.fill()
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            let trackingRect = bounds.intersection(visibleRect)
            guard !trackingRect.isNull, !trackingRect.isEmpty else {
                if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
                hoverTrackingArea = nil
                setHovered(false)
                return
            }
            // Replacing an unchanged tracking area during SwiftUI updates can
            // interrupt an in-progress rollover. Keep it until geometry changes.
            if hoverTrackingArea?.rect != trackingRect {
                if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
                let area = NSTrackingArea(rect: trackingRect,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                    owner: self, userInfo: nil)
                addTrackingArea(area)
                hoverTrackingArea = area
                scheduleHoverRefresh()
            }
            refreshPointer()
        }

        override func mouseEntered(with event: NSEvent) { pointerDidChange() }
        override func mouseMoved(with event: NSEvent) { pointerDidChange() }
        override func mouseExited(with event: NSEvent) { pointerDidChange() }

        private func pointerDidChange() {
            refreshPointer()
            scheduleHoverRefresh()
        }

        private func scheduleHoverRefresh() {
            guard ownsControls, !hoverRefreshScheduled else { return }
            hoverRefreshScheduled = true
            // Reconcile once after AppKit's own tracking callbacks. Re-read the
            // pointer rather than replaying a stale enter/exit event. No polling.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hoverRefreshScheduled = false
                guard self.ownsControls else { return }
                self.refreshPointer()
                self.nativeContainer.refreshButtonAppearance()
            }
        }

        @objc private func refreshPointer() {
            guard ownsControls, let window else { setHovered(false); return }
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let isAppOrWindowActive = window.isKeyWindow || window.isMainWindow || NSApp.isActive
            setHovered(isAppOrWindowActive && !sheetIsPresenting && window.attachedSheet == nil
                       && !isHiddenOrHasHiddenAncestor
                       && bounds.contains(point) && visibleRect.contains(point))
        }

        private func setHovered(_ hovered: Bool) {
            nativeContainer.mouseInside = hovered
            appearanceOverlay.hovered = hovered
            nativeContainer.updateDrawingMask()
        }

        private func findNativeTitlebarView() -> NSView? {
            guard let window = attachedWindow, let themeFrame = window.contentView?.superview else { return nil }
            for container in themeFrame.subviews where container.className == "NSTitlebarContainerView" {
                for subview in container.subviews where subview.className == "NSTitlebarView" {
                    return subview
                }
                return container
            }
            return nil
        }

        private func hideTitlebarContainer() {
            guard ownsControls, let window = attachedWindow,
                  let themeFrame = window.contentView?.superview else { return }
            for subview in themeFrame.subviews where subview.className == "NSTitlebarContainerView" {
                if !titlebarVisibility.contains(where: { $0.view === subview }) {
                    titlebarVisibility.append(TitlebarVisibility(view: subview, wasHidden: subview.isHidden))
                }
                if !subview.isHidden { subview.isHidden = true }
            }
            if window.styleMask.contains(.fullScreen) {
                for w in NSApp.windows where w.className == "NSToolbarFullScreenWindow" {
                    if !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
                }
            }
        }

        func synchronize() {
            guard ownsControls else { return }
            attach()
            updateTrackingAreas()
            refreshPointer()
            // A handoff or fullscreen transition may replace native cells while
            // the pointer stays inside the group and no new enter event arrives.
            scheduleHoverRefresh()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            attachedWindow = window
            if let previous = Self.owners.object(forKey: window), previous !== self {
                // Transfer the original AppKit parents/frames, not the previous
                // host's sidebar coordinates. Retire it before moving buttons.
                nativeControls = previous.nativeControls
                titlebarVisibility = previous.titlebarVisibility
                previous.nativeControls.removeAll()
                previous.titlebarVisibility.removeAll()
                previous.appearanceOverlay.buttonFrames = []
                previous.appearanceOverlay.isHidden = true
                previous.setHovered(false)
                NotificationCenter.default.removeObserver(previous)
            }
            Self.owners.setObject(self, forKey: window)
            sheetIsPresenting = window.attachedSheet != nil
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(fullscreenTransitioning),
                name: NSWindow.willEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(enterFullscreen),
                name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(fullscreenTransitioning),
                name: NSWindow.willExitFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(exitFullscreen),
                name: NSWindow.didExitFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                name: NSWindow.didEndLiveResizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(willBeginSheet),
                name: NSWindow.willBeginSheetNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(didEndSheet),
                name: NSWindow.didEndSheetNotification, object: window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateDidChange),
                    name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateDidChange),
                    name: name, object: nil)
            }
            synchronize()
            scheduleReconciliation()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func attach() {
            guard ownsControls, let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            hideTitlebarContainer()

            if nativeContainer.superview == nil { addSubview(nativeContainer) }
            nativeContainer.frame = bounds
            nativeContainer.autoresizingMask = [.width, .height]
            nativeContainer.wantsLayer = true
            let hasSheet = sheetIsPresenting || window.attachedSheet != nil

            var currentButtons: [NativeControl] = []
            let defaultParent = findNativeTitlebarView()
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                let existing = nativeControls.first(where: { $0.button === button })
                if button.superview !== nativeContainer {
                    let rawParent = button.superview
                    // A regular handoff already has an original record. Never
                    // use a titlebar's entire bounds as a button's saved frame.
                    let parent = (rawParent is ControlsContainer) ? defaultParent : (rawParent ?? defaultParent)
                    let record = existing ?? NativeControl(kind: kind, button: button, parent: parent,
                                                           frame: button.frame, wasHidden: button.isHidden,
                                                           postedFrameChanges: button.postsFrameChangedNotifications)
                    button.removeFromSuperview()
                    nativeContainer.addSubview(button)
                    currentButtons.append(record)
                } else if let existing {
                    currentButtons.append(existing)
                } else {
                    currentButtons.append(NativeControl(kind: kind, button: button, parent: defaultParent,
                                                        frame: button.frame, wasHidden: button.isHidden,
                                                        postedFrameChanges: button.postsFrameChangedNotifications))
                }
                button.isHidden = hasSheet
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: button)
                NotificationCenter.default.addObserver(self, selector: #selector(nativeButtonFrameDidChange),
                    name: NSView.frameDidChangeNotification, object: button)
            }
            // AppKit can replace widgets during window transitions. Remove only
            // obsolete widgets still owned by this container, never another host.
            for old in nativeControls where !currentButtons.contains(where: { $0.button === old.button }) {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old.button)
                old.button.postsFrameChangedNotifications = old.postedFrameChanges
                if old.button.superview === nativeContainer {
                    old.button.removeFromSuperview()
                }
            }
            nativeControls = currentButtons

            if appearanceOverlay.superview == nil {
                appearanceOverlay.hovered = false
                appearanceOverlay.frame = bounds
                appearanceOverlay.autoresizingMask = [.width, .height]
                appearanceOverlay.wantsLayer = true
                addSubview(appearanceOverlay, positioned: .above, relativeTo: nativeContainer)
            }
            appearanceOverlay.isHidden = hasSheet
            layoutButtons()
        }

        private func layoutButtons() {
            guard ownsControls else { return }
            let hasSheet = sheetIsPresenting || window?.attachedSheet != nil
            ControlsContainer.isPositioningButtons = true
            defer { ControlsContainer.isPositioningButtons = false }
            for control in nativeControls where control.button.superview === nativeContainer {
                let button = control.button
                let index: CGFloat = control.kind == .closeButton ? 0 : (control.kind == .miniaturizeButton ? 1 : 2)
                button.isHidden = hasSheet
                button.setFrameOrigin(NSPoint(x: index * 22,
                    y: (bounds.height - button.frame.height) / 2))
            }
            appearanceOverlay.isHidden = hasSheet
            appearanceOverlay.buttonFrames = nativeControls
                .filter { $0.button.superview === nativeContainer }
                .map { (kind: $0.kind, frame: $0.button.frame) }
            needsDisplay = true
            refreshPointer()
        }

        override func layout() {
            super.layout()
            layoutButtons()
        }

        @objc private func windowDidResize(_ notification: Notification) {
            synchronize()
            scheduleReconciliation()
        }

        @objc private func nativeButtonFrameDidChange(_ notification: Notification) {
            guard ownsControls, let button = notification.object as? NSButton,
                  button.superview !== nativeContainer else { return }
            // AppKit can return widgets to its titlebar *after* didExitFullScreen
            // and our next-turn reconciliation. Observe that actual reset rather
            // than guessing a delay or continuously polling the window.
            scheduleReconciliation()
        }

        @objc private func windowStateDidChange(_ notification: Notification) {
            guard ownsControls, window != nil else {
                refreshPointer()
                return
            }
            synchronize()
            scheduleReconciliation()
        }

        @objc private func willBeginSheet(_ notification: Notification) {
            guard ownsControls else { return }
            // Intentional for the custom sidebar: while the parent is modal,
            // hide both presentations so AppKit cannot expose a duplicate row
            // or apparently available window actions. didEndSheet restores them.
            sheetIsPresenting = true
            setHovered(false)
            hideTitlebarContainer()
            for control in nativeControls {
                control.button.isHidden = true
            }
            appearanceOverlay.isHidden = true
        }

        @objc private func didEndSheet(_ notification: Notification) {
            guard ownsControls else { return }
            sheetIsPresenting = false
            synchronize()
            scheduleReconciliation()
        }

        private func restore() {
            ControlsContainer.isPositioningButtons = true
            defer { ControlsContainer.isPositioningButtons = false }
            let defaultParent = findNativeTitlebarView()
            for control in nativeControls {
                control.button.postsFrameChangedNotifications = control.postedFrameChanges
                guard control.button.superview === nativeContainer else { continue }
                let destination = (control.parent is ControlsContainer || control.parent == nil) ? defaultParent : control.parent
                destination?.addSubview(control.button)
                control.button.frame = control.frame
                control.button.isHidden = control.wasHidden
            }
            nativeControls.removeAll()
            appearanceOverlay.removeFromSuperview()
            for state in titlebarVisibility { state.view?.isHidden = state.wasHidden }
            titlebarVisibility.removeAll()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            setHovered(false)
            if ownsControls {
                restore()
                if let attachedWindow { Self.owners.removeObject(forKey: attachedWindow) }
            } else {
                nativeControls.removeAll()
                titlebarVisibility.removeAll()
                appearanceOverlay.removeFromSuperview()
            }
            attachedWindow = nil
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            hoverTrackingArea = nil
        }

        @objc private func fullscreenTransitioning(_ notification: Notification) {
            setHovered(false)
            hideTitlebarContainer()
            scheduleReconciliation()
        }

        @objc private func enterFullscreen(_ notification: Notification) {
            synchronize()
            scheduleReconciliation()
        }

        @objc private func exitFullscreen(_ notification: Notification) {
            synchronize()
            scheduleReconciliation()
        }

        // AppKit may finish its own titlebar layout after posting a notification.
        // Coalesce one follow-up; no polling or self-rescheduling loop.
        private func scheduleReconciliation() {
            guard ownsControls, !reconciliationScheduled else { return }
            reconciliationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconciliationScheduled = false
                self.synchronize()
            }
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}

enum SidebarRevealRegion {
    static let edgeWidth: CGFloat = 2

    static func contains(_ point: CGPoint?, sidebarWidth: CGFloat, revealed: Bool) -> Bool {
        guard let point else { return false }
        // Keep the edge-to-panel gutter active only AFTER a real edge entry.
        return point.x >= 0 && point.x < (revealed ? sidebarWidth + 6 : edgeWidth)
    }
}

/// Track the stationary native window surface, including events delivered to
/// WebKit children. SwiftUI hover regions can miss a second edge entry after
/// their overlay/sidebar hierarchy changes. Never intercept or synthesize input.
struct BrowserWindowPointerMonitor: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: PointerView, context: Context) { view.onMove = onMove }
    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.stop()
        view.onMove = nil
    }

    final class PointerView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var monitor: Any?
        private var area: NSTrackingArea?
        private weak var monitoredWindow: NSWindow?
        private var previouslyAcceptedMouseMoves = false

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitoredWindow = window
            previouslyAcceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseMoved, .mouseEntered, .mouseExited,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
            ]) { [weak self] event in
                self?.handle(event)
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(cancelPointer), name: name, object: window)
            }
            updateTrackingAreas()
        }

        override func updateTrackingAreas() {
            if let area { removeTrackingArea(area) }
            area = nil
            if window != nil, monitor != nil {
                let next = NSTrackingArea(rect: .zero,
                    options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
                addTrackingArea(next)
                area = next
            }
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { handle(event) }
        override func mouseMoved(with event: NSEvent) { handle(event) }
        override func mouseExited(with event: NSEvent) { handle(event) }

        func handle(_ event: NSEvent) {
            guard monitor != nil, let window, event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            // A child tracking area's exit is NOT a window exit. Derive the
            // result from the actual stable bounds, never the event's type.
            onMove?(bounds.contains(point) ? point : nil)
        }

        @objc private func cancelPointer() { onMove?(nil) }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let area { removeTrackingArea(area) }
            area = nil
            NotificationCenter.default.removeObserver(self)
            monitoredWindow?.acceptsMouseMovedEvents = previouslyAcceptedMouseMoves
            monitoredWindow = nil
        }
    }
}

/// SwiftUI owns this container; the manager owns the web view's lifetime.
struct WebContentView: NSViewRepresentable {
    let view: WKWebView?
    let focusRequest: Int
    let canFocus: Bool
    let hasDialog: Bool
    var isResizing = false
    var onInteraction: (() -> Void)? = nil

    func makeNSView(context: Context) -> HostView { HostView() }
    static func dismantleNSView(_ host: HostView, coordinator: ()) { host.invalidate() }
    func updateNSView(_ host: HostView, context: Context) {
        host.setLiveResize(isResizing)
        host.display(view)
        host.canFocus = canFocus
        host.suppressAccessibilityChildren = hasDialog
        host.onInteraction = onInteraction
        guard host.focusRequest != focusRequest else { return }
        host.focusRequest = focusRequest
        DispatchQueue.main.async { [weak host] in
            guard let host, host.canFocus, host.focusRequest == focusRequest else { return }
            // WebKit temporarily owns/reparents an element-fullscreen view.
            // Do not steal its focus back into the browser window.
            if let view = host.hosted, view.fullscreenState != .notInFullscreen { return }
            host.window?.makeFirstResponder(host.hosted ?? host)
        }
    }

    final class HostView: NSView {
        // Weak ownership includes element-fullscreen reparenting. A second
        // pane cannot silently steal the same live view from its first host.
        private static let owners = NSMapTable<WKWebView, HostView>.weakToWeakObjects()
        weak var hosted: WKWebView?
        private weak var desired: WKWebView?
        private var leavingFullscreen = false
        private var invalidated = false
        private var resizeRequested = false
        private weak var resizingView: WKWebView?
        private var backgroundObservation: NSKeyValueObservation?
        var onInteraction: (() -> Void)?
        private var interactionMonitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // SwiftUI clipping alone can leave the embedded native surface's
            // exposed rect larger than the pane during rapid divider changes.
            clipsToBounds = true
            wantsLayer = true
            autoresizesSubviews = false
        }
        required init?(coder: NSCoder) { return nil }
        override var isFlipped: Bool { true }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            layoutHostedView()
        }
        override func setBoundsSize(_ size: NSSize) {
            super.setBoundsSize(size)
            layoutHostedView()
        }
        override func layout() {
            super.layout()
            layoutHostedView()
        }

        private func layoutHostedView() {
            guard !invalidated, let hosted, hosted.superview === self else { return }
            // Set the viewport in the SAME native layout pass as its host,
            // rather than animating a composited old-sized WebKit surface.
            // Never touch a view reparented by element fullscreen.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A newly made/removed SwiftUI host can have zero bounds for one
            // layout pass. Keep the last real viewport instead of asking
            // WebKit to reflow to zero and repaint again on Space re-entry.
            if hasViewport, hosted.frame != bounds { hosted.frame = bounds }
            layer?.backgroundColor = hosted.underPageBackgroundColor.cgColor
            CATransaction.commit()
        }

        private var hasViewport: Bool {
            bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
        }

        func setLiveResize(_ resizing: Bool) {
            resizeRequested = resizing && !invalidated
            synchronizeLiveResize()
        }

        private func synchronizeLiveResize() {
            let target = resizeRequested && hosted?.superview === self ? hosted : nil
            guard resizingView !== target else { return }
            finishLiveResize()
            if let target {
                resizingView = target
                // Divider drags don't resize NSWindow, so AppKit doesn't send
                // these notifications for us. WebKit uses them to coordinate
                // drawing-area updates with continuous native viewport changes.
                target.viewWillStartLiveResize()
            }
        }

        private func finishLiveResize() {
            guard let resizingView else { return }
            self.resizingView = nil
            resizingView.viewDidEndLiveResize()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopInteractionMonitor()
            guard window != nil, !invalidated else { return }
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, self.hosted != nil else { return event }
                let interacts: Bool
                if event.type == .keyDown {
                    interacts = self.containsPageView(window.firstResponder as? NSView)
                } else {
                    // Bounds alone also include SwiftUI overlays (command bar,
                    // pane controls, notices). They must not focus the page
                    // underneath a click intended for one of those controls.
                    let content = window.contentView
                    let point = content?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                    let hit = content?.hitTest(point)
                    interacts = self.containsPageView(hit)
                }
                if interacts { self.onInteraction?() }
                return event // Never consume or duplicate a website event.
            }
        }

        private func stopInteractionMonitor() {
            if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
            interactionMonitor = nil
        }

        func containsPageView(_ candidate: NSView?) -> Bool {
            guard let hosted, let candidate else { return false }
            return candidate === hosted || candidate.isDescendant(of: hosted)
        }

        @discardableResult
        func display(_ view: WKWebView?) -> Bool {
            guard !invalidated, canOwn(view) else { return false }
            desired = view
            guard !leavingFullscreen, hosted !== view else { return true }
            if let previous = hosted, previous.fullscreenState != .notInFullscreen {
                leavingFullscreen = true
                previous.closeAllMediaPresentations { [weak self] in
                    guard let self, !self.invalidated else { return }
                    self.leavingFullscreen = false
                    _ = self.install(self.desired)
                }
                return true
            }
            return install(view)
        }

        private func canOwn(_ view: WKWebView?) -> Bool {
            guard let view, let owner = Self.owners.object(forKey: view) else { return true }
            return owner === self
        }

        func invalidate() {
            invalidated = true
            stopInteractionMonitor()
            onInteraction = nil
            canFocus = false
            focusRequest = -1
            desired = nil
            releaseHostedView()
        }

        private func releaseHostedView() {
            finishLiveResize()
            backgroundObservation = nil
            if let hosted {
                if Self.owners.object(forKey: hosted) === self { Self.owners.removeObject(forKey: hosted) }
                if hosted.superview === self { hosted.removeFromSuperview() }
            }
            hosted = nil
            layer?.backgroundColor = nil
        }

        @discardableResult
        private func install(_ view: WKWebView?) -> Bool {
            guard canOwn(view) else { return false }
            releaseHostedView()
            hosted = view
            if let view {
                Self.owners.setObject(self, forKey: view)
                view.removeFromSuperview()
                view.autoresizingMask = []
                // Size before attachment: WebKit must not start drawing at the
                // previous Space's viewport and immediately resize afterward.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if hasViewport { view.frame = bounds }
                layer?.backgroundColor = view.underPageBackgroundColor.cgColor
                addSubview(view)
                CATransaction.commit()
                layoutHostedView()
                // Use WebKit's computed page background, not the browser's
                // light/dark appearance, for any not-yet-painted resize area.
                backgroundObservation = view.observe(\.underPageBackgroundColor) { [weak self, weak view] _, _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view, self.hosted === view else { return }
                        self.layoutHostedView()
                    }
                }
                synchronizeLiveResize()
            }
            return true
        }
        var focusRequest = -1
        var canFocus = false
        var suppressAccessibilityChildren = false
        override var acceptsFirstResponder: Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityChildren() -> [Any]? {
            guard !suppressAccessibilityChildren, let hosted else { return [] }
            return [hosted]
        }
    }
}
