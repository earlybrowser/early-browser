// SPDX-License-Identifier: MPL-2.0

import AppKit
import WebKit

/// WebKit re-sends a key-down that the page left unhandled through AppKit,
/// whose final fallback is the unhandled-key alert. Websites often act on a
/// plain key without preventing its default (YouTube's T toggles theater
/// mode), and menus/key equivalents have already declined the re-sent event.
/// Plain keys therefore end silently, as in other browsers. Command/Control
/// shortcuts keep AppKit's standard path, including its alert for unassigned
/// shortcuts, and Tab keeps window key-view navigation.
enum UnhandledPageKey {
    private static let tabKeyCode: UInt16 = 48

    static func keepsStandardFallback(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == tabKeyCode || !modifiers.intersection([.command, .control]).isEmpty
    }
}

/// Early owns page, link, image and selected-text menus. An ordinary native
/// popup avoids AppKit's contextual-menu augmentation; editable fields and
/// media keep WebKit's native menus.
@MainActor
final class BrowserWebView: WKWebView, @preconcurrency NSSharingServicePickerDelegate {
    /// What a trusted right-click landed on, already validated by the manager.
    struct ContextTarget: Equatable {
        var link: URL?
        var image: URL?
        var selection: String?
    }

    /// Menu actions that the owning manager performs for this page.
    enum ContextAction: Equatable {
        case back, forward, reload, savePage, printPage
        case downloadLink(URL)
        case openImageInNewTab(URL), saveImage(URL), copyImage(URL)
        case searchSelection(String)
        case translatePage
    }

    /// Key-downs already delivered to the page. WebKit re-sends the same event
    /// object when the page declines it; weak entries vanish with the event.
    private let pageKeyEvents = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])

    override func keyDown(with event: NSEvent) {
        guard pageKeyEvents.contains(event) else {
            pageKeyEvents.add(event)
            super.keyDown(with: event)
            return
        }
        pageKeyEvents.remove(event)
        guard UnhandledPageKey.keepsStandardFallback(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return }
        super.keyDown(with: event)
    }

    var onOpenWindowLink: ((URL) -> Void)?
    /// "Translate to …" or "Show Original" for the page menu; nil leaves it out.
    var pageTranslationTitle: (() -> String?)?
    var onOpenBackgroundLink: ((URL) -> Void)?
    var onContextAction: ((ContextAction) -> Void)?
    var shareLink: ((URL) -> Void)?
    /// Tests capture the built menu instead of entering modal menu tracking.
    var presentMenu: ((NSMenu, NSPoint) -> Void)?
    private var sharingPicker: NSSharingServicePicker?
    private var linkMenuPoint = NSPoint.zero
    /// Copies link and image addresses as plain text.
    var copyLink: (URL) -> Void = { url in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    private var shownLinkMenu: NSMenu?
    /// Developer Mode with Web Inspector: right-clicks open WebKit's menu, which
    /// gets Early's items and keeps WebKit's own Inspect Element.
    var inspectsElements = false
    private var pendingContextTarget: (target: ContextTarget, time: Date)?
    static let inspectElementIdentifier = "WKMenuItemIdentifierInspectElement"
    var onInteractionEnded: (() -> Void)?
    var hasActiveInteraction: Bool { shownLinkMenu != nil || sharingPicker != nil }

    func makeLinkMenu(for url: URL) -> NSMenu { makeContextMenu(for: ContextTarget(link: url)) }

    /// Only working actions appear; a link inside an image or a selected link
    /// shows each applicable section, and anything else gets the page menu.
    func makeContextMenu(for target: ContextTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        func item(_ title: String, _ action: Selector, _ value: Any? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.isEnabled = enabled
            return item
        }
        let perform = #selector(performContextAction(_:))
        var sections: [[NSMenuItem]] = []
        if let link = target.link {
            sections.append([
                item("Open Link in New Tab", #selector(openBackgroundLink(_:)), link),
                item("Open Link in New Window", #selector(openWindowLink(_:)), link),
                item("Download Linked File", perform, ContextAction.downloadLink(link)),
                item("Copy Link", #selector(copyLinkAddress(_:)), link),
                item("Share", #selector(shareLinkAddress(_:)), link)
            ])
        }
        if let image = target.image {
            let web = ["http", "https"].contains(image.scheme?.lowercased() ?? "")
            var images: [NSMenuItem] = []
            if web { images.append(item("Open Image in New Tab", perform, ContextAction.openImageInNewTab(image))) }
            images.append(item("Save Image As…", perform, ContextAction.saveImage(image)))
            images.append(item("Copy Image", perform, ContextAction.copyImage(image)))
            if web { images.append(item("Copy Image Address", #selector(copyLinkAddress(_:)), image)) }
            sections.append(images)
        }
        if let text = target.selection {
            let excerpt = Self.menuExcerpt(text)
            sections.append([
                item("Search with Google for “\(excerpt)”", perform, ContextAction.searchSelection(text)),
                item("Copy", #selector(copySelection(_:))),
                item("Look Up “\(excerpt)”", #selector(lookUpSelection(_:)), text),
                item("Share", #selector(shareSelection(_:)), text)
            ])
        }
        if sections.isEmpty {
            sections.append([
                item("Back", perform, ContextAction.back, enabled: canGoBack),
                item("Forward", perform, ContextAction.forward, enabled: canGoForward),
                item("Reload", perform, ContextAction.reload)
            ])
            sections.append([
                item("Save Page As…", perform, ContextAction.savePage, enabled: url != nil),
                item("Print…", perform, ContextAction.printPage, enabled: url != nil)
            ])
            if let title = pageTranslationTitle?() {
                sections.append([item(title, perform, ContextAction.translatePage)])
            }
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            section.forEach { menu.addItem($0) }
        }
        return menu
    }

    /// Early's items in WebKit's menu, then Inspect Element. Fields and media
    /// keep WebKit's menu as they always do, now with Inspect Element too.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        defer { super.willOpenMenu(menu, with: event) }
        guard inspectsElements, let pending = pendingContextTarget.take(),
              Date().timeIntervalSince(pending.time) < 2 else { return }
        fill(menu, for: pending.target)
    }

    func fill(_ menu: NSMenu, for target: ContextTarget) {
        let inspect = menu.items.first { $0.identifier?.rawValue == Self.inspectElementIdentifier }
        menu.removeAllItems()
        menu.autoenablesItems = false
        let early = makeContextMenu(for: target)
        let items = early.items
        early.removeAllItems()
        items.forEach(menu.addItem)
        if let inspect {
            menu.addItem(.separator())
            menu.addItem(inspect)
        }
    }

    /// Web Inspector opens in its own window: a docked one would share the
    /// pane with a page Early sizes to fill it.
    func detachInspector() {
        Self.inspector(of: self)?.perform(NSSelectorFromString("detach"))
    }

    static func inspector(of view: WKWebView) -> NSObject? {
        guard view.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return view.value(forKey: "_inspector") as? NSObject
    }

    static func menuExcerpt(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 30 ? String(words.prefix(29)) + "…" : words
    }

    func showContextMenu(for target: ContextTarget) {
        if inspectsElements {
            // WebKit's own menu follows this message; it is filled in below.
            pendingContextTarget = (target, Date())
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        linkMenuPoint = point
        let menu = makeContextMenu(for: target)
        if let presentMenu {
            presentMenu(menu, point)
            return
        }
        shownLinkMenu?.cancelTrackingWithoutAnimation()
        shownLinkMenu = menu
        defer {
            if shownLinkMenu === menu { shownLinkMenu = nil }
            onInteractionEnded?()
        }
        // Do not use popUpContextMenu: that is the system insertion path which
        // bypassed the proposed-menu filters. This still displays a native NSMenu.
        menu.popUp(positioning: nil, at: point, in: self)
    }

    func cancelLinkMenu() {
        shownLinkMenu?.cancelTrackingWithoutAnimation()
        shownLinkMenu = nil
        sharingPicker?.close()
        sharingPicker = nil
        onInteractionEnded?()
    }

    @objc private func openWindowLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenWindowLink?(url)
    }

    @objc private func openBackgroundLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenBackgroundLink?(url)
    }

    @objc private func copyLinkAddress(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        copyLink(url)
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ContextAction else { return }
        onContextAction?(action)
    }

    @objc private func copySelection(_ sender: NSMenuItem) {
        // WebKit copies the selection with its rich formatting.
        NSApp.sendAction(#selector(NSText.copy(_:)), to: self, from: sender)
    }

    @objc private func lookUpSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        showDefinition(for: NSAttributedString(string: text), at: linkMenuPoint)
    }

    @objc private func shareSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        presentSharingPicker(items: [text])
    }

    @objc private func shareLinkAddress(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let shareLink { shareLink(url); return }
        presentSharingPicker(items: [url])
    }

    /// Show a native chooser only: no destination is selected automatically.
    private func presentSharingPicker(items: [Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.sharingPicker?.close()
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = self
            self.sharingPicker = picker
            let point = NSPoint(x: min(max(self.linkMenuPoint.x, 0), self.bounds.maxX),
                                y: min(max(self.linkMenuPoint.y, 0), self.bounds.maxY))
            picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)),
                        of: self, preferredEdge: .minY)
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // AppKit delivers picker UI callbacks on the main thread; its legacy
        // Objective-C delegate protocol does not express actor isolation.
        if sharingPicker === picker { sharingPicker = nil }
        onInteractionEnded?()
    }
}
