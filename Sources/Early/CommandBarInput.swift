// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A bounded native editor rather than a single-line field: URLs can wrap, large
/// pastes scroll, and AppKit keeps selection, undo, and input-method ownership.
struct CommandBarInput: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    var maxHeight: CGFloat = 120
    var canFocus: () -> Bool = { true }
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCompositionChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMoveSelection: (Int) -> Bool = { _ in false }

    func makeNSView(context: Context) -> CommandBarInputControl {
        let control = CommandBarInputControl()
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: CommandBarInputControl, context: Context) {
        control.onTextChange = { text = $0 }
        control.onHeightChange = onHeightChange
        control.onFocusChange = onFocusChange
        control.onCompositionChange = onCompositionChange
        control.onSubmit = onSubmit
        control.onCancel = onCancel
        control.onMoveSelection = onMoveSelection
        control.canFocus = canFocus
        control.maximumHeight = maxHeight
        control.prepareForFocusRequest(focusRequest)
        control.updateText(text)
        control.requestFocus(focusRequest)
    }

    static func dismantleNSView(_ control: CommandBarInputControl, coordinator: ()) {
        control.invalidate()
    }
}

@MainActor
final class CommandBarInputControl: NSView, NSTextViewDelegate {
    static let minimumHeight: CGFloat = 24
    let scrollView = NSScrollView()
    let textView = CommandBarTextView(frame: .zero)
    var onTextChange: (String) -> Void = { _ in }
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCompositionChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMoveSelection: (Int) -> Bool = { _ in false }
    var canFocus: () -> Bool = { true }
    var maximumHeight: CGFloat = 120 {
        didSet { if maximumHeight != oldValue { needsLayout = true } }
    }
    private(set) var measuredHeight: CGFloat = minimumHeight
    private(set) var contentHeight: CGFloat = minimumHeight
    private(set) var isComposing = false
    private var isUpdatingText = false
    private var requestedFocus: Int?
    private var pendingFocus: Int?
    private var focusGeneration = 0
    private var heightCallbackPending = false
    private var publishedHeight: CGFloat?
    private var invalidated = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.contentView.drawsBackground = false
        scrollView.setAccessibilityElement(false)
        addSubview(scrollView)

        textView.delegate = self
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .labelColor
        textView.insertionPointColor = .secondaryLabelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.setAccessibilityIdentifier("commandBar.query")
        textView.setAccessibilityLabel("Search or enter a URL")
        textView.setAccessibilityPlaceholderValue("Search or enter a URL")
        textView.onCompositionChange = { [weak self] composing in
            guard let self, self.isComposing != composing else { return }
            self.isComposing = composing
            // Publish before the binding changes so suggestions never process a
            // partially composed input-method candidate as a committed query.
            self.onCompositionChange(composing)
        }
        textView.onFocusChange = { [weak self] focused in self?.onFocusChange(focused) }
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let viewportChanged = scrollView.frame.size != bounds.size
        measure(width: bounds.width)
        if viewportChanged, window?.firstResponder === textView {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    /// Kept separate from layout so wrapping and large-paste behavior can be
    /// verified without opening a window or synthesizing any keyboard events.
    @discardableResult
    func measure(width: CGFloat) -> CGFloat {
        let width = max(1, width.isFinite ? width : 1)
        let limit = max(Self.minimumHeight, maximumHeight.isFinite ? maximumHeight : 120)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: max(Self.minimumHeight, bounds.height))
        textView.setFrameSize(NSSize(width: width, height: max(Self.minimumHeight, textView.frame.height)))
        guard let container = textView.textContainer, let manager = textView.layoutManager else {
            return Self.minimumHeight
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let font = textView.font ?? .systemFont(ofSize: 18)
        let lineHeight = manager.defaultLineHeight(for: font)
        let used = manager.usedRect(for: container)
        let extra = manager.extraLineFragmentTextContainer === container ? manager.extraLineFragmentRect.maxY : 0
        contentHeight = ceil(max(Self.minimumHeight, lineHeight, used.maxY, extra))
        measuredHeight = min(contentHeight, limit)
        scrollView.hasVerticalScroller = contentHeight > measuredHeight
        textView.setFrameSize(NSSize(width: width, height: max(contentHeight, measuredHeight)))
        publishHeight()
        return measuredHeight
    }

    func updateText(_ text: String) {
        // Observation echoes must not reset the caret, native undo grouping, or
        // marked text. A real programmatic replacement starts a new edit history.
        guard textView.string != text, !isComposing else { return }
        isUpdatingText = true
        let selection = textView.selectedRange()
        textView.string = text
        let count = (text as NSString).length
        let location = min(selection.location, count)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        textView.undoManager?.removeAllActions()
        textView.needsDisplay = true
        isUpdatingText = false
        needsLayout = true
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingText else { return }
        textView.needsDisplay = true
        onTextChange(textView.string)
        measure(width: bounds.width)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    /// Returning false is intentional: AppKit must retain native editing and
    /// input-method commands whenever the browser has no action to perform.
    func handleCommand(_ selector: Selector, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !isComposing, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !modifiers.contains(.shift), !modifiers.contains(.option) else { return false }
            onSubmit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard modifiers.intersection([.shift, .option, .command, .control]).isEmpty else { return false }
            return onMoveSelection(selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
        default:
            return false
        }
    }

    func requestFocus(_ request: Int) {
        guard requestedFocus != request, !invalidated else { return }
        requestedFocus = request
        pendingFocus = request
        queueFocus()
    }

    func prepareForFocusRequest(_ request: Int) {
        // An explicit new presentation (for example another Command-L) replaces
        // the previous query. Ordinary redraws must leave its candidate intact.
        guard requestedFocus != request, isComposing else { return }
        let wasUpdatingText = isUpdatingText
        isUpdatingText = true
        defer { isUpdatingText = wasUpdatingText }
        // Some input methods emit an edit notification while unmarking. It must
        // not write the previous candidate over the newly presented model query.
        textView.unmarkText()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
            queueFocus()
        }
    }

    @objc private func windowBecameKey() { queueFocus() }

    private func queueFocus() {
        guard let request = pendingFocus, let window else { return }
        focusGeneration += 1
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.invalidated, self.focusGeneration == generation,
                  self.pendingFocus == request, self.window === window, window.isKeyWindow,
                  !self.isHiddenOrHasHiddenAncestor, self.canFocus() else { return }
            // The presentation gate rejects an intervening outside click before
            // SwiftUI removes this native view. Do not compare old responders:
            // AppKit may assign its default one while first opening the window.
            self.pendingFocus = nil
            if window.makeFirstResponder(self.textView) {
                self.textView.selectAll(nil)
                self.textView.scrollRangeToVisible(self.textView.selectedRange())
            }
        }
    }

    private func publishHeight() {
        guard !heightCallbackPending, !invalidated, publishedHeight != measuredHeight else { return }
        heightCallbackPending = true
        // SwiftUI state cannot be changed synchronously from updateNSView/layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.heightCallbackPending = false
            guard self.publishedHeight != self.measuredHeight else { return }
            self.publishedHeight = self.measuredHeight
            self.onHeightChange(self.measuredHeight)
        }
    }

    func invalidate() {
        invalidated = true
        pendingFocus = nil
        focusGeneration += 1
        NotificationCenter.default.removeObserver(self)
        textView.delegate = nil
        textView.undoManager?.removeAllActions()
        textView.onCompositionChange = { _ in }
        textView.onFocusChange = { _ in }
        onTextChange = { _ in }
        onHeightChange = { _ in }
        onFocusChange = { _ in }
        onCompositionChange = { _ in }
        onSubmit = {}
        onCancel = {}
        onMoveSelection = { _ in false }
        canFocus = { false }
    }
}

@MainActor
final class CommandBarTextView: NSTextView {
    var onCompositionChange: (Bool) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    private let editingUndoManager = UndoManager()

    override var undoManager: UndoManager? { editingUndoManager }

    // Preserve commandBar.query's existing text-field accessibility contract even
    // though its editor can now wrap and scroll instead of truncating one line.
    override func accessibilityRole() -> NSAccessibility.Role? { .textField }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { nil }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(visibleRect, to: nil))
    }

    override func accessibilityActivationPoint() -> NSPoint {
        let frame = accessibilityFrame()
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onCompositionChange(true)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange(false)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onCompositionChange(hasMarkedText())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 18),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        NSAttributedString(string: "Search or enter a URL", attributes: attributes)
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: CommandBarInputControl.minimumHeight))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        insertionPointColor = .secondaryLabelColor
    }
}
