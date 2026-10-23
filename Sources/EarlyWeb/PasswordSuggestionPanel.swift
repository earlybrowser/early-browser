// SPDX-License-Identifier: MPL-2.0

import AppKit

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
    private var list: ListView?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { !items.isEmpty }

    /// `field` is in screen coordinates; the list goes below it, or above
    /// when there is no room.
    func show(_ items: [PasswordSuggestion], title: String, below field: NSRect, in parent: NSWindow) {
        guard !items.isEmpty else { close(); return }
        if items != self.items { highlighted = nil }
        self.items = items
        self.title = title
        let panel = self.panel ?? makePanel()
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
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        let list = ListView()
        list.onChoose = { [weak self] in self?.choose(at: $0) }
        list.onHover = { [weak self] in self?.setHighlight($0) }
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.topAnchor.constraint(equalTo: background.topAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        self.panel = panel
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

    /// The rows; clicks land on the first click although the list is never key.
    final class ListView: NSView {
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
            for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted }
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

        private func updateColors() {
            layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.cgColor : nil
            title.textColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
            detail.textColor = isHighlighted ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
            icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
            setAccessibilitySelected(isHighlighted)
        }
    }
}
