import AppKit
import SwiftUI
import WebKit

/// Keep the real AppKit controls for native glass rendering and window actions.
/// A mouse-transparent overlay draws neutral circles at rest and symbols on hover.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsHost { ControlsHost() }
    func updateNSView(_ view: ControlsHost, context: Context) { view.synchronize() }
    static func dismantleNSView(_ view: ControlsHost, coordinator: ()) { view.detach() }

    private final class ControlsContainer: NSView {
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
                method_setImplementation(m1, imp_implementationWithBlock(block1))
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
                method_setImplementation(m2, imp_implementationWithBlock(block2))
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
        private struct NativeControl {
            let button: NSButton
            weak var parent: NSView?
            let frame: NSRect
            let wasHidden: Bool
        }
        private var nativeControls: [NativeControl] = []
        private let nativeContainer = ControlsContainer()
        private let appearanceOverlay = AppearanceOverlay()
        private var hoverTrackingArea: NSTrackingArea?

        private final class AppearanceOverlay: NSView {
            var buttonFrames: [NSRect] = [] { didSet { needsDisplay = true } }
            var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func isAccessibilityElement() -> Bool { false }
            override var isOpaque: Bool { false }
            override func draw(_ dirtyRect: NSRect) {
                if hovered {
                    // AppKit still draws the glass and handles clicks. Its normal
                    // titlebar group supplies symbols, so supply just those here
                    // when hosting the controls in our compact sidebar group.
                    NSColor.black.withAlphaComponent(0.65).setStroke()
                    NSColor.black.withAlphaComponent(0.65).setFill()
                    for (index, frame) in buttonFrames.enumerated() {
                        let x = frame.midX, y = frame.midY
                        let mark = NSBezierPath()
                        mark.lineWidth = 1.5
                        mark.lineCapStyle = .round
                        switch index {
                        case 0:
                            mark.move(to: NSPoint(x: x - 2.5, y: y - 2.5))
                            mark.line(to: NSPoint(x: x + 2.5, y: y + 2.5))
                            mark.move(to: NSPoint(x: x - 2.5, y: y + 2.5))
                            mark.line(to: NSPoint(x: x + 2.5, y: y - 2.5))
                            mark.stroke()
                        case 1:
                            mark.move(to: NSPoint(x: x - 3.5, y: y))
                            mark.line(to: NSPoint(x: x + 3.5, y: y))
                            mark.stroke()
                        default:
                            mark.move(to: NSPoint(x: x - 3.5, y: y - 1.5))
                            mark.line(to: NSPoint(x: x - 3.5, y: y + 3.5))
                            mark.line(to: NSPoint(x: x + 1.5, y: y + 3.5))
                            mark.close()
                            mark.move(to: NSPoint(x: x - 1.5, y: y - 3.5))
                            mark.line(to: NSPoint(x: x + 3.5, y: y - 3.5))
                            mark.line(to: NSPoint(x: x + 3.5, y: y + 1.5))
                            mark.close()
                            mark.fill()
                        }
                    }
                    return
                }
                let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                for frame in buttonFrames {
                    // Cover the native button and its outer shadow to ensure
                    // no color bleed, without drawing any rectangular background.
                    let backing = NSBezierPath(ovalIn: frame.insetBy(dx: -1.5, dy: -1.5))
                    NSColor.windowBackgroundColor.setFill()
                    backing.fill()

                    let circle = NSBezierPath(ovalIn: frame)
                    circle.fill()
                    NSColor.labelColor.withAlphaComponent(highContrast ? 0.25 : 0.12).setFill()
                    circle.fill()
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            // A non-clipping SwiftUI host can report visibleRect larger than
            // bounds. Never use inVisibleRect here: it can cover the whole window.
            let area = NSTrackingArea(rect: bounds.intersection(visibleRect),
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
            refreshPointer()
        }

        override func mouseEntered(with event: NSEvent) { refreshPointer() }
        override func mouseExited(with event: NSEvent) { setHovered(false) }

        @objc private func refreshPointer() {
            guard let window else { setHovered(false); return }
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            setHovered(window.isKeyWindow && !isHiddenOrHasHiddenAncestor
                       && bounds.contains(point) && visibleRect.contains(point))
        }

        private func setHovered(_ hovered: Bool) {
            appearanceOverlay.hovered = hovered
        }

        private func hideTitlebarContainer() {
            guard let window, let themeFrame = window.contentView?.superview else { return }
            for subview in themeFrame.subviews where subview.className == "NSTitlebarContainerView" {
                if !subview.isHidden { subview.isHidden = true }
            }
        }

        func synchronize() {
            attach()
            refreshPointer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(enterFullscreen),
                name: NSWindow.willEnterFullScreenNotification, object: window)
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
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateDidChange),
                    name: name, object: window)
            }
            synchronize()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func attach() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            hideTitlebarContainer()

            if nativeContainer.superview == nil { addSubview(nativeContainer) }
            nativeContainer.frame = bounds
            nativeContainer.autoresizingMask = [.width, .height]
            nativeContainer.wantsLayer = true
            let hasSheet = window.attachedSheet != nil

            var currentButtons: [NativeControl] = []
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                if button.superview !== nativeContainer {
                    let parent = button.superview
                    let wasHidden = button.isHidden
                    let frame = button.frame
                    button.removeFromSuperview()
                    nativeContainer.addSubview(button)
                    currentButtons.append(NativeControl(button: button, parent: parent,
                                                        frame: frame, wasHidden: wasHidden))
                } else if let existing = nativeControls.first(where: { $0.button === button }) {
                    currentButtons.append(existing)
                } else {
                    currentButtons.append(NativeControl(button: button, parent: nil,
                                                        frame: button.frame, wasHidden: false))
                }
                button.isHidden = hasSheet
            }
            if !currentButtons.isEmpty {
                nativeControls = currentButtons
            }

            if appearanceOverlay.superview == nil {
                appearanceOverlay.hovered = false
                appearanceOverlay.frame = bounds
                appearanceOverlay.autoresizingMask = [.width, .height]
                appearanceOverlay.wantsLayer = true
                appearanceOverlay.layer?.zPosition = 1
                addSubview(appearanceOverlay, positioned: .above, relativeTo: nativeContainer)
            }
            layoutButtons()
        }

        private func layoutButtons() {
            let hasSheet = window?.attachedSheet != nil
            ControlsContainer.isPositioningButtons = true
            defer { ControlsContainer.isPositioningButtons = false }
            for (index, control) in nativeControls.enumerated() {
                let button = control.button
                button.isHidden = hasSheet
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 22,
                    y: (bounds.height - button.frame.height) / 2))
            }
            appearanceOverlay.buttonFrames = nativeControls.map { $0.button.frame }
            needsDisplay = true
            refreshPointer()
        }

        override func layout() {
            super.layout()
            layoutButtons()
        }

        @objc private func windowDidResize(_ notification: Notification) {
            hideTitlebarContainer()
            attach()
        }

        @objc private func windowStateDidChange(_ notification: Notification) {
            hideTitlebarContainer()
            refreshPointer()
        }

        @objc private func willBeginSheet(_ notification: Notification) {
            hideTitlebarContainer()
            for control in nativeControls {
                control.button.isHidden = true
            }
            appearanceOverlay.needsDisplay = true
        }

        @objc private func didEndSheet(_ notification: Notification) {
            hideTitlebarContainer()
            attach()
            for control in nativeControls {
                control.button.isHidden = false
            }
            layoutButtons()
        }

        private func restore() {
            ControlsContainer.isPositioningButtons = true
            defer { ControlsContainer.isPositioningButtons = false }
            for control in nativeControls {
                control.parent?.addSubview(control.button)
                control.button.frame = control.frame
                control.button.isHidden = control.wasHidden
            }
            nativeControls.removeAll()
            appearanceOverlay.removeFromSuperview()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func enterFullscreen(_ notification: Notification) {
            if let window, let themeFrame = window.contentView?.superview {
                for subview in themeFrame.subviews where subview.className == "NSTitlebarContainerView" {
                    subview.isHidden = false
                }
            }
            restore()
        }

        @objc private func exitFullscreen(_ notification: Notification) {
            synchronize()
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

/// SwiftUI owns this container; the manager owns the web view's lifetime.
struct WebContentView: NSViewRepresentable {
    let view: WKWebView?
    let focusRequest: Int
    let canFocus: Bool
    let hasDialog: Bool

    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ host: HostView, context: Context) {
        if host.hosted !== view {
            host.hosted?.removeFromSuperview()
            host.hosted = view
            if let view {
                view.removeFromSuperview()
                view.frame = host.bounds
                view.autoresizingMask = [.width, .height]
                host.addSubview(view)
            }
        }
        host.canFocus = canFocus
        host.suppressAccessibilityChildren = hasDialog
        guard host.focusRequest != focusRequest else { return }
        host.focusRequest = focusRequest
        DispatchQueue.main.async { [weak host] in
            guard let host, host.canFocus, host.focusRequest == focusRequest else { return }
            host.window?.makeFirstResponder(host.hosted ?? host)
        }
    }

    final class HostView: NSView {
        weak var hosted: WKWebView?
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
