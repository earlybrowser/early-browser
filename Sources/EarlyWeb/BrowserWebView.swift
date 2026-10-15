import AppKit
import WebKit

/// Early owns link-menu presentation. An ordinary native popup avoids AppKit's
/// contextual-menu augmentation; non-link editing menus remain WebKit-native.
@MainActor
final class BrowserWebView: WKWebView, @preconcurrency NSSharingServicePickerDelegate {
    var onOpenWindowLink: ((URL) -> Void)?
    var onOpenBackgroundLink: ((URL) -> Void)?
    var shareLink: ((URL) -> Void)?
    private var sharingPicker: NSSharingServicePicker?
    private var linkMenuPoint = NSPoint.zero
    var copyLink: (URL) -> Void = { url in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    private var shownLinkMenu: NSMenu?

    func makeLinkMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        let actions: [(String, Selector)] = [
            ("Open Link in New Tab", #selector(openBackgroundLink(_:))),
            ("Open Link in New Window", #selector(openWindowLink(_:))),
            ("Copy Link", #selector(copyLinkAddress(_:))),
            ("Share", #selector(shareLinkAddress(_:)))
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    func showLinkMenu(for url: URL) {
        guard let window, window.attachedSheet == nil else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        linkMenuPoint = point
        let menu = makeLinkMenu(for: url)
        shownLinkMenu?.cancelTrackingWithoutAnimation()
        shownLinkMenu = menu
        defer { if shownLinkMenu === menu { shownLinkMenu = nil } }
        // Do not use popUpContextMenu: that is the system insertion path which
        // bypassed the proposed-menu filters. This still displays a native NSMenu.
        menu.popUp(positioning: nil, at: point, in: self)
    }

    func cancelLinkMenu() {
        shownLinkMenu?.cancelTrackingWithoutAnimation()
        shownLinkMenu = nil
        sharingPicker?.close()
        sharingPicker = nil
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

    @objc private func shareLinkAddress(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let shareLink { shareLink(url); return }
        // Show a native chooser only: no destination is selected automatically.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.sharingPicker?.close()
            let picker = NSSharingServicePicker(items: [url])
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
    }
}
