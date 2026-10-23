// SPDX-License-Identifier: MPL-2.0

import AppKit

/// View Page Source: the page's markup as it is now, read-only and searchable.
@MainActor
final class PageSourceWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PageSourceWindow] = []
    static let explanation = "The page as it is now, including changes made by its scripts. Early doesn’t download it again."

    let textView: NSTextView

    @discardableResult
    static func show(_ source: String, url: URL?, title: String) -> PageSourceWindow {
        let controller = PageSourceWindow(source: source, url: url, title: title)
        open.append(controller)
        controller.showWindow(nil)
        return controller
    }

    static var openWindows: [PageSourceWindow] { open }

    init(source: String, url: URL?, title: String) {
        let window = SourceWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Source of \(title)"
        window.subtitle = url?.absoluteString ?? ""
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.setAccessibilityIdentifier("pageSource.window")

        let note = NSTextField(wrappingLabelWithString: Self.explanation)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.string = source
        text.setAccessibilityLabel("Page source")
        text.setAccessibilityIdentifier("pageSource.text")
        textView = text

        let content = NSView()
        content.addSubview(note)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        window.initialFirstResponder = text
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }

    /// The browser's Find commands belong to its web pages; here Command-F and
    /// Command-G search the source with the text view's find bar.
    private final class SourceWindow: NSWindow {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = event.charactersIgnoringModifiers?.lowercased(), flags.contains(.command),
                  let text = (windowController as? PageSourceWindow)?.textView else { return super.performKeyEquivalent(with: event) }
            let action: NSTextFinder.Action? = switch (key, flags.contains(.shift)) {
            case ("f", false): .showFindInterface
            case ("g", false): .nextMatch
            case ("g", true): .previousMatch
            default: nil
            }
            guard let action else { return super.performKeyEquivalent(with: event) }
            let item = NSMenuItem()
            item.tag = action.rawValue
            text.performTextFinderAction(item)
            return true
        }
    }
}
