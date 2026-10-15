import AppKit
import EarlyCore
import SwiftUI

struct CommandBarView: View {
    @Bindable var model: BrowserWindowModel
    var suggestionListHeight: CGFloat = 220
    @FocusState private var queryIsFocused: Bool
    @State private var hoveredSuggestion: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .background(CommandBarCardAnchor(model: model))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
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
                    model.dismissCommandBar()
                    return nil
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
