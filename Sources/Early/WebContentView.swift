import AppKit
import SwiftUI
import WebKit

/// Keep the real AppKit controls for native glass rendering and window actions.
/// A mouse-transparent overlay draws neutral circles at rest and symbols on hover.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsHost { ControlsHost() }
    func updateNSView(_ view: ControlsHost, context: Context) { view.synchronize() }
    static func dismantleNSView(_ view: ControlsHost, coordinator: ()) { view.detach() }

    final class ControlsHost: NSView {
        private struct NativeControl {
            let button: NSButton
            weak var parent: NSView?
            let frame: NSRect
            let wasHidden: Bool
        }
        private var nativeControls: [NativeControl] = []
        private let nativeContainer = NSView()
        private let appearanceOverlay = AppearanceOverlay()
        private var hoverTrackingArea: NSTrackingArea?

        private final class AppearanceOverlay: NSView {
            var buttonFrames: [NSRect] = [] { didSet { needsDisplay = true } }
            var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func isAccessibilityElement() -> Bool { false }
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
                NSColor.windowBackgroundColor.setFill()
                bounds.fill()
                let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                NSColor.labelColor.withAlphaComponent(highContrast ? 0.25 : 0.12).setFill()
                for frame in buttonFrames {
                    // Match the native button's diameter; do not shrink the
                    // resting circle relative to the glass hover appearance.
                    NSBezierPath(ovalIn: frame).fill()
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
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshPointer),
                    name: name, object: window)
            }
            synchronize()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func attach() {
            guard nativeControls.isEmpty, let window, !window.styleMask.contains(.fullScreen) else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            if nativeContainer.superview == nil { addSubview(nativeContainer) }
            nativeContainer.frame = bounds
            nativeContainer.autoresizingMask = [.width, .height]
            nativeContainer.wantsLayer = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                nativeControls.append(NativeControl(button: button, parent: button.superview,
                                                    frame: button.frame, wasHidden: button.isHidden))
                nativeContainer.addSubview(button)
                button.isHidden = false
            }
            appearanceOverlay.hovered = false
            appearanceOverlay.frame = bounds
            appearanceOverlay.autoresizingMask = [.width, .height]
            appearanceOverlay.wantsLayer = true
            appearanceOverlay.layer?.zPosition = 1
            addSubview(appearanceOverlay, positioned: .above, relativeTo: nativeContainer)
            needsLayout = true
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            for (index, control) in nativeControls.enumerated() {
                let button = control.button
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 22,
                    y: (bounds.height - button.frame.height) / 2))
            }
            appearanceOverlay.buttonFrames = nativeControls.map { $0.button.frame }
            needsDisplay = true
            refreshPointer()
        }

        private func restore() {
            for control in nativeControls {
                control.parent?.addSubview(control.button)
                control.button.frame = control.frame
                control.button.isHidden = control.wasHidden
            }
            nativeControls.removeAll()
            appearanceOverlay.removeFromSuperview()
        }

        func detach() { restore(); NotificationCenter.default.removeObserver(self) }
        @objc private func enterFullscreen(_ notification: Notification) { restore() }
        @objc private func exitFullscreen(_ notification: Notification) { synchronize() }
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
