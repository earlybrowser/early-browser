// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

struct CommandBarView: View {
    @Bindable var model: BrowserWindowModel
    var suggestionListHeight: CGFloat = 220
    @FocusState private var queryIsFocused: Bool
    @State private var hoveredSuggestion: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                TextField("Search or enter a URL", text: Binding(
                    get: { model.coordinator.commandBar?.query ?? "" },
                    set: {
                        model.updateQuery($0)
                    }
                ))
                .font(.title3)
                .textFieldStyle(.plain)
                .focused($queryIsFocused)
                .accessibilityLabel("Search or enter a URL")
                .accessibilityIdentifier("commandBar.query")
                .onSubmit { model.submit(searchSuggestion: model.suggestions.selectedSuggestion) }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    // Let the input method own candidate navigation during composition.
                    guard !model.suggestions.isRefreshing, !model.suggestions.results.isEmpty,
                          (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return .ignored }
                    model.suggestions.moveSelection(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                Button {
                    model.dismissCommandBar()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss command bar")
                .help("Dismiss (Escape)")
            }
            if let message = model.submissionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("commandBar.message")
            }
            if !model.suggestions.results.isEmpty {
                VStack(spacing: 12) {
                    Divider()
                    suggestionList
                }
                .transition(.opacity)
            }
            if model.suggestions.unavailable {
                Text("Suggestions unavailable. Press Return to search.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("commandBar.suggestionsUnavailable")
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(CommandBarCardAnchor(model: model, queryIsFocused: queryIsFocused))
        .background {
            if reduceTransparency || contrast == .increased {
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.thickMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.24), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.results.count)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.unavailable)
        .task(id: model.coordinator.commandBarFocusRequest) {
            model.refreshSuggestions()
            // Let the sidebar button finish its click/focus transaction before
            // moving the first responder into the newly presented editor.
            await Task.yield()
            guard !Task.isCancelled else { return }
            queryIsFocused = true
        }
        .onDisappear { model.suggestions.cancel() }
        .onChange(of: model.suggestions.results) { _, _ in hoveredSuggestion = nil }
        .onExitCommand { model.dismissCommandBar() }
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.suggestions.results.enumerated()), id: \.offset) { index, suggestion in
                        Button { model.submit(searchSuggestion: suggestion) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                Text(suggestion).lineLimit(1).truncationMode(.tail)
                                    .contentTransition(.opacity)
                                Spacer(minLength: 0)
                            }
                            .font(.body)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .background(Color.primary.opacity(model.suggestions.selectedIndex == index || hoveredSuggestion == index ? 0.08 : 0),
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.suggestions.isRefreshing)
                        .accessibilityLabel("Search Google for \(suggestion)")
                        .accessibilityIdentifier("commandBar.suggestion.\(index)")
                        .accessibilityAddTraits(model.suggestions.selectedIndex == index ? .isSelected : [])
                        .onHover { hoveredSuggestion = $0 ? index : nil }
                        .id(index)
                    }
                }
            }
            .opacity(model.suggestions.isRefreshing ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.isRefreshing)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.results)
            .frame(height: min(suggestionListHeight, CGFloat(model.suggestions.results.count * 36 - 2)))
            .onChange(of: model.suggestions.selectedIndex) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .accessibilityIdentifier("commandBar.suggestions")
    }
}

private struct CommandBarCardAnchor: NSViewRepresentable {
    let model: BrowserWindowModel
    let queryIsFocused: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.model = model
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.model = model
        if queryIsFocused {
            // The field editor is attached after SwiftUI's focus transaction.
            // Color the idle caret too, before the first edit notification.
            DispatchQueue.main.async { [weak view] in view?.updateFocusedCaret() }
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class AnchorView: NSView {
        var model: BrowserWindowModel?
        private var monitor: Any?
        private weak var editingField: NSTextField?
        private weak var fieldEditor: NSTextView?
        private var originalCaretColor: NSColor?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }

        func startMonitoring() {
            stopMonitoring()
            NotificationCenter.default.addObserver(self, selector: #selector(editingBegan(_:)),
                name: NSControl.textDidBeginEditingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(editingEnded(_:)),
                name: NSControl.textDidEndEditingNotification, object: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard let model = self.model, model.coordinator.commandBar != nil else {
                    return event
                }
                guard let window = self.window, event.window === window else {
                    return event
                }
                guard !self.bounds.isEmpty else {
                    return event
                }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(localPoint) {
                    return event
                } else {
                    // Let this very click reach its original destination. Do
                    // not queue a web-content focus request that could steal
                    // focus from the sidebar control or page field it selects.
                    if let editor = self.fieldEditor, window.firstResponder === editor {
                        window.makeFirstResponder(nil)
                    }
                    model.dismissCommandBar(restoreFocus: false)
                    return event
                }
            }
        }

        func stopMonitoring() {
            NotificationCenter.default.removeObserver(self, name: NSControl.textDidBeginEditingNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSControl.textDidEndEditingNotification, object: nil)
            restoreCaret()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        @objc private func editingBegan(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            styleCaret(in: field)
        }

        func updateFocusedCaret() {
            guard let editor = window?.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField else { return }
            styleCaret(in: field)
        }

        private func styleCaret(in field: NSTextField) {
            guard monitor != nil, let window, field.window === window,
                  bounds.intersects(field.convert(field.bounds, to: self)),
                  let editor = field.currentEditor() as? NSTextView else { return }
            guard editingField !== field || fieldEditor !== editor else { return }
            restoreCaret()
            editingField = field
            fieldEditor = editor
            originalCaretColor = editor.insertionPointColor
            editor.insertionPointColor = .secondaryLabelColor
        }

        @objc private func editingEnded(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === editingField else { return }
            restoreCaret()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            fieldEditor?.insertionPointColor = .secondaryLabelColor
        }

        private func restoreCaret() {
            // AppKit shares a field editor across controls in this window.
            // Do not leak the command bar's caret color into other editors.
            if let originalCaretColor { fieldEditor?.insertionPointColor = originalCaretColor }
            originalCaretColor = nil
            fieldEditor = nil
            editingField = nil
        }
    }
}
