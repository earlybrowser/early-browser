// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore

/// The window's look for the list under a sign-in field: its Space's theme,
/// like Early's other floating tools.
public struct PasswordListStyle: Equatable, Sendable {
    public var theme: WindowTheme
    public var allowsTransparency: Bool

    public init(theme: WindowTheme, allowsTransparency: Bool) {
        self.theme = theme
        self.allowsTransparency = allowsTransparency
    }
}

/// What the list under a sign-in field offers.
public enum PasswordSuggestion: Equatable, Sendable {
    case login(UUID, username: String)
    case strongPassword(String)
    case manage
}

/// The list below a focused sign-in field, like Safari's AutoFill menu. It
/// never becomes key, so typing stays in the page, which forwards the arrow,
/// Return and Escape keys while the list is open.
@MainActor
final class PasswordSuggestionPanel {
    private(set) var items: [PasswordSuggestion] = []
    private(set) var title = ""
    private(set) var highlighted: Int?
    var onChoose: ((PasswordSuggestion) -> Void)?
    var onHighlight: ((Int?) -> Void)?
    var onClose: (() -> Void)?
    private var panel: Panel?
    private(set) var surface: SurfaceView?
    private(set) var list: ListView?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { !items.isEmpty }

    /// `field` is in screen coordinates; the list goes below it, or above
    /// when there is no room.
    func show(_ items: [PasswordSuggestion], title: String, below field: NSRect, in parent: NSWindow,
              style: PasswordListStyle = PasswordListStyle(theme: .space(.gray), allowsTransparency: true)) {
        guard !items.isEmpty else { close(); return }
        if items != self.items { highlighted = nil }
        self.items = items
        self.title = title
        let panel = self.panel ?? makePanel()
        // A child window doesn't take its parent's appearance (private windows are always dark).
        panel.appearance = parent.effectiveAppearance
        surface?.style = style
        list?.tint = surface?.tint ?? .controlAccentColor
        list?.update(title: title, items: items, highlighted: highlighted)
        let size = NSSize(width: min(max(field.width, 250), 380), height: list?.fittingHeight ?? 0)
        var origin = NSPoint(x: field.minX, y: field.minY - 4 - size.height)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        if origin.y < screen.minY { origin.y = field.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            observe(parent)
            self.parent = parent
        }
        // Only over a window on screen; one that was never shown (tests) shows nothing.
        guard parent.isVisible else { return }
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func moveHighlight(_ step: Int) {
        guard !items.isEmpty else { return }
        let next = highlighted.map { ($0 + step + items.count) % items.count } ?? (step > 0 ? 0 : items.count - 1)
        setHighlight(next)
    }

    func setHighlight(_ index: Int?) {
        let index = index.flatMap { items.indices.contains($0) ? $0 : nil }
        guard index != highlighted else { return }
        highlighted = index
        list?.update(title: title, items: items, highlighted: index)
        onHighlight?(index)
    }

    /// Return with a highlighted row chooses it.
    @discardableResult
    func chooseHighlighted() -> Bool {
        guard let highlighted, items.indices.contains(highlighted) else { return false }
        choose(at: highlighted)
        return true
    }

    func choose(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        close()
        onChoose?(item)
    }

    func close() {
        guard panel != nil || !items.isEmpty else { return }
        items = []
        highlighted = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        parent = nil
        onClose?()
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Passwords")
        let background = SurfaceView()
        background.onAppearanceChange = { [weak self] in
            guard let self, let surface = self.surface else { return }
            self.list?.tint = surface.tint
            self.list?.update(title: self.title, items: self.items, highlighted: self.highlighted)
        }
        let list = ListView()
        list.onChoose = { [weak self] in self?.choose(at: $0) }
        list.onHover = { [weak self] in self?.setHighlight($0) }
        background.embed(list)
        panel.contentView = background
        self.panel = panel
        self.surface = background
        self.list = list
        return panel
    }

    /// The window losing focus, moving between Spaces or changing size closes the list.
    private func observe(_ window: NSWindow) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification,
                                          NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The Space's chrome, as SwiftUI's floating tools draw it: a material,
    /// the theme's gradient over it, and a theme-colored edge. Solid with
    /// Reduce Transparency, translucent chrome off, or increased contrast.
    final class SurfaceView: NSView {
        var style = PasswordListStyle(theme: .space(.gray), allowsTransparency: true) {
            didSet { if style != oldValue { refresh() } }
        }
        var onAppearanceChange: (() -> Void)?
        private let material = PassthroughMaterial()
        private let dim = PassthroughView()
        private let shade = GradientView()
        private let edge = PassthroughView()
        static let cornerRadius: CGFloat = 10

        /// Drawing only: clicks go through to the rows.
        private class PassthroughView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        private final class PassthroughMaterial: NSVisualEffectView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        /// The theme's gradient, as the view's own layer.
        private final class GradientView: PassthroughView {
            override func makeBackingLayer() -> CALayer { CAGradientLayer() }
            var gradient: CAGradientLayer { layer as! CAGradientLayer }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            dim.wantsLayer = true
            shade.wantsLayer = true
            shade.gradient.startPoint = CGPoint(x: 0, y: 1)
            shade.gradient.endPoint = CGPoint(x: 1, y: 0)
            // The edge sits above the rows, like the SwiftUI surfaces' stroke.
            edge.wantsLayer = true
            edge.layer?.cornerRadius = Self.cornerRadius
            edge.layer?.borderWidth = 1
            for view in [material, dim, shade, edge] {
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            refresh()
        }

        /// The list goes above the background and below the edge.
        func embed(_ content: NSView) {
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content, positioned: .below, relativeTo: edge)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }


        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        private var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

        /// The theme's edge color, also used for icons and the highlighted row.
        var tint: NSColor { Self.color(style.theme.focusBorder(isDark: isDark, increasedContrast: increasedContrast)) }

        static func color(_ rgb: SpaceThemeRGB, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
        }

        override func layout() {
            super.layout()
            for view in [material, dim, shade, edge] { view.frame = bounds }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refresh()
            onAppearanceChange?()
        }

        private func refresh() {
            let dark = isDark
            let solid = !style.allowsTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            effectiveAppearance.performAsCurrentDrawingAppearance {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if increasedContrast {
                    material.isHidden = true
                    dim.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    shade.isHidden = true
                } else {
                    material.isHidden = solid
                    dim.layer?.backgroundColor = dark && !solid ? NSColor.black.withAlphaComponent(0.30).cgColor : nil
                    shade.isHidden = false
                    shade.gradient.colors = [Self.color(style.theme.chromeTop(isDark: dark)).cgColor,
                                             Self.color(style.theme.chromeBottom(isDark: dark)).cgColor]
                    shade.gradient.opacity = solid ? 1 : (dark ? 0.64 : 0.68)
                }
                edge.layer?.borderColor = tint.withAlphaComponent(increasedContrast ? 1 : 0.55).cgColor
                CATransaction.commit()
            }
        }
    }

    /// The rows; clicks land on the first click although the list is never key.
    final class ListView: NSView {
        var tint = NSColor.controlAccentColor
        var onChoose: ((Int) -> Void)?
        var onHover: ((Int?) -> Void)?
        private var rows: [RowView] = []
        private let header = NSTextField(labelWithString: "")
        private var pressed: Int?
        static let headerHeight: CGFloat = 24
        static let rowHeight: CGFloat = 38
        static let manageHeight: CGFloat = 30

        override init(frame: NSRect) {
            super.init(frame: frame)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.lineBreakMode = .byTruncatingMiddle
            addSubview(header)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        var fittingHeight: CGFloat {
            Self.headerHeight + rows.reduce(0) { $0 + $1.height } + 6
        }

        func update(title: String, items: [PasswordSuggestion], highlighted: Int?) {
            header.stringValue = title
            if rows.count != items.count || zip(rows, items).contains(where: { $0.item != $1 }) {
                rows.forEach { $0.removeFromSuperview() }
                rows = items.enumerated().map { index, item in
                    let row = RowView(item: item)
                    row.onPress = { [weak self] in self?.onChoose?(index) }
                    addSubview(row)
                    return row
                }
            }
            for (index, row) in rows.enumerated() {
                row.tint = tint
                row.isHighlighted = index == highlighted
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            header.frame = NSRect(x: 12, y: 6, width: bounds.width - 24, height: 15)
            var y = Self.headerHeight
            for row in rows {
                row.frame = NSRect(x: 5, y: y, width: bounds.width - 10, height: row.height)
                y += row.height
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        private func row(at event: NSEvent) -> Int? {
            let point = convert(event.locationInWindow, from: nil)
            return rows.firstIndex { $0.frame.contains(point) }
        }

        override func mouseMoved(with event: NSEvent) { onHover?(row(at: event)) }
        override func mouseExited(with event: NSEvent) { onHover?(nil) }
        override func mouseDown(with event: NSEvent) { pressed = row(at: event) }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = nil }
            guard let index = row(at: event), index == pressed else { return }
            onChoose?(index)
        }
    }

    final class RowView: NSView {
        let item: PasswordSuggestion
        var onPress: (() -> Void)?
        private let icon = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let separator = NSBox()

        var height: CGFloat { item == .manage ? ListView.manageHeight : ListView.rowHeight }

        var tint = NSColor.controlAccentColor {
            didSet { if tint != oldValue { updateColors() } }
        }

        var isHighlighted = false {
            didSet {
                guard isHighlighted != oldValue else { return }
                updateColors()
            }
        }

        init(item: PasswordSuggestion) {
            self.item = item
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 5
            title.lineBreakMode = .byTruncatingTail
            detail.lineBreakMode = .byTruncatingMiddle
            detail.font = .systemFont(ofSize: 11)
            switch item {
            case .login(_, let username):
                icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
                title.stringValue = username.isEmpty ? "No user name" : username
                title.font = .systemFont(ofSize: 13, weight: .medium)
                detail.stringValue = "••••••••"
            case .strongPassword(let password):
                icon.image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)
                title.stringValue = "Use Strong Password"
                title.font = .systemFont(ofSize: 13, weight: .medium)
                detail.stringValue = password
                detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            case .manage:
                title.stringValue = "Manage Passwords…"
                title.font = .systemFont(ofSize: 13)
                separator.boxType = .separator
                addSubview(separator)
            }
            icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            [icon, title, detail].forEach(addSubview)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(accessibilityTitle)
            updateColors()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var accessibilityTitle: String {
            switch item {
            case .login(_, let username): username.isEmpty ? "Password with no user name" : "Password for \(username)"
            case .strongPassword: "Use Strong Password"
            case .manage: "Manage Passwords"
            }
        }

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return true
        }

        override var isFlipped: Bool { true }

        // The list is never key, so every click is a first click: the row
        // takes it whole, over its labels, and passes it to the list.
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func layout() {
            super.layout()
            if item == .manage {
                separator.frame = NSRect(x: 7, y: 0, width: bounds.width - 14, height: 1)
                title.frame = NSRect(x: 9, y: 8, width: bounds.width - 18, height: 17)
                return
            }
            icon.frame = NSRect(x: 9, y: (bounds.height - 18) / 2, width: 18, height: 18)
            title.frame = NSRect(x: 34, y: 3, width: bounds.width - 42, height: 17)
            detail.frame = NSRect(x: 34, y: 20, width: bounds.width - 42, height: 14)
        }

        /// Like Site Controls' active rows: a soft wash of the Space's color.
        private func updateColors() {
            layer?.backgroundColor = isHighlighted ? tint.withAlphaComponent(0.22).cgColor : nil
            title.textColor = .labelColor
            detail.textColor = .secondaryLabelColor
            icon.contentTintColor = tint
            setAccessibilitySelected(isHighlighted)
        }
    }
}
