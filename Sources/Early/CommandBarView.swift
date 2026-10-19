// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

struct CommandBarView: View {
    @Bindable var model: BrowserWindowModel
    var availableHeight: CGFloat = 600
    @State private var inputHeight: CGFloat = 24
    @State private var hoveredSuggestion: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var layout: CommandBarLayout {
        CommandBarLayout(availableHeight: availableHeight,
            hasSuggestions: !model.suggestions.results.isEmpty,
            statusCount: (model.submissionMessage == nil ? 0 : 1) + (model.suggestions.unavailable ? 1 : 0))
    }

    var body: some View {
        let focusRequest = model.coordinator.commandBarFocusRequest
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .frame(height: 24)
                    .accessibilityHidden(true)
                CommandBarInput(text: Binding(
                    get: { model.coordinator.commandBar?.query ?? "" },
                    set: {
                        model.updateQuery($0, isComposing: model.commandBarIsComposing)
                    }
                ), focusRequest: focusRequest,
                    maxHeight: layout.maximumInputHeight,
                    canFocus: { model.coordinator.commandBar != nil && model.coordinator.commandBarFocusRequest == focusRequest },
                    onHeightChange: { inputHeight = $0 }, onFocusChange: { _ in },
                    onCompositionChange: { composing in
                        model.commandBarIsComposing = composing
                        if !composing { model.refreshSuggestions() }
                    },
                    onSubmit: { model.perform(.submit(searchSuggestion: model.suggestions.selectedSuggestion), source: .commandBar) },
                    onCancel: { model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar) },
                    onMoveSelection: { delta in
                        guard !model.commandBarIsComposing, !model.suggestions.isRefreshing,
                              !model.suggestions.results.isEmpty else { return false }
                        model.suggestions.moveSelection(delta)
                        return true
                    },
                    onCompleteSuggestion: {
                        guard !model.commandBarIsComposing, model.coordinator.commandBar != nil else { return nil }
                        return model.suggestions.selectedSuggestion
                    })
                .frame(height: min(inputHeight, layout.maximumInputHeight))
                Button {
                    model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .accessibilityLabel("Dismiss command bar")
                .help("Dismiss (Escape)")
            }
            if let message = model.submissionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(message)
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
                    .lineLimit(2)
                    .accessibilityIdentifier("commandBar.suggestionsUnavailable")
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(CommandBarCardAnchor(model: model))
        .background {
            if model.preferences.spaceThemes, contrast != .increased {
                BrowserChromeBackground(spaceColor: model.coordinator.activeSpace?.color ?? .gray,
                    floating: true, allowsTransparency: model.preferences.translucentChrome)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if reduceTransparency || !model.preferences.translucentChrome || contrast == .increased {
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.thickMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.22), radius: 24, y: 10)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandBar.card")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.results.count)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.unavailable)
        .task(id: model.coordinator.commandBarFocusRequest) { model.refreshSuggestions() }
        .onDisappear { model.suggestions.cancel(); model.commandBarIsComposing = false }
        .onChange(of: model.suggestions.results) { _, _ in hoveredSuggestion = nil }
        .onExitCommand {
            guard !model.commandBarIsComposing else { return }
            model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar)
        }
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.suggestions.results.enumerated()), id: \.offset) { index, suggestion in
                        Button { model.perform(.submit(searchSuggestion: suggestion), source: .commandBar) } label: {
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
            .frame(height: min(layout.suggestionHeight(inputHeight: inputHeight), CGFloat(model.suggestions.results.count * 36 - 2)))
            .onChange(of: model.suggestions.selectedIndex) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .accessibilityIdentifier("commandBar.suggestions")
    }
}

/// A full-window SwiftUI overlay can absorb wheel events even where it draws
/// nothing. Resolve the underlying native page target without changing focus,
/// faking a scroll in JavaScript, or forwarding events inside the card.
@MainActor
enum CommandBarScrollRouting {
    static func target(at windowPoint: NSPoint, outside card: NSView, in page: NSView) -> NSView? {
        guard !card.bounds.contains(card.convert(windowPoint, from: nil)),
              !page.isHiddenOrHasHiddenAncestor, let parent = page.superview,
              page.visibleRect.contains(page.convert(windowPoint, from: nil)) else { return nil }
        return page.hitTest(parent.convert(windowPoint, from: nil))
    }
}

private struct CommandBarCardAnchor: NSViewRepresentable {
    let model: BrowserWindowModel

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.model = model
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class AnchorView: NSView {
        var model: BrowserWindowModel?
        private var monitor: Any?

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
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
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
                if event.type == .scrollWheel {
                    guard window.attachedSheet == nil,
                          let page = model.activePage?.view, page.window === window,
                          let target = CommandBarScrollRouting.target(at: event.locationInWindow, outside: self, in: page) else {
                        return event
                    }
                    // Deliver the original event exactly once, preserving its
                    // phase, momentum and deltas for WebKit's native gestures.
                    target.scrollWheel(with: event)
                    return nil
                }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(localPoint) {
                    return event
                } else {
                    // Let this very click reach its original destination. Do
                    // not queue a web-content focus request that could steal
                    // focus from the sidebar control or page field it selects.
                    if let editor = window.firstResponder as? NSTextView,
                       editor.window === window, self.bounds.intersects(editor.convert(editor.bounds, to: self)) {
                        window.makeFirstResponder(nil)
                    }
                    model.perform(.dismissCommandBar(restoreFocus: false), source: .commandBar)
                    return event
                }
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

    }
}
