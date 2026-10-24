// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

struct CommandBarView: View {
    @Bindable var model: BrowserWindowModel
    var availableHeight: CGFloat = 600
    @State private var inputHeight: CGFloat = 24
    @State private var hoveredItem: String?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    /// A selected or hovered row: a wash of the Space's color where the bar
    /// wears the theme, neutral gray where it doesn't.
    private func rowHighlight(selected: Bool, hovered: Bool) -> CommandRowHighlight {
        let tint = model.tintsChrome
            ? model.chromeTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color : nil
        return CommandRowHighlight(selected: selected, hovered: hovered, tint: tint, increasedContrast: contrast == .increased)
    }

    private var hasResults: Bool {
        !model.visibleCommandResults.isEmpty || !model.suggestions.results.isEmpty
    }

    private var totalRows: Int {
        model.visibleCommandResults.count + model.suggestions.results.count
    }

    private var layout: CommandBarLayout {
        CommandBarLayout(availableHeight: availableHeight,
            hasSuggestions: hasResults,
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
                    onHeightChange: { inputHeight = $0 }, onFocusChange: { focused in
                        if focused { model.refreshPasteKind() }
                    },
                    onCompositionChange: { composing in
                        model.commandBarIsComposing = composing
                        if !composing { model.refreshSuggestions() }
                    },
                    onSubmit: { model.performCommandBarSelection() },
                    onCancel: { model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar) },
                    onMoveSelection: { model.moveCommandBarSelection($0) },
                    onCompleteSuggestion: {
                        guard !model.commandBarIsComposing, model.coordinator.commandBar != nil,
                              model.selectedCommandResult == nil else { return nil }
                        return model.suggestions.selectedSuggestion
                    },
                    // Command search lists commands; it has nothing to paste into.
                    pasteAndGoTitle: { model.coordinator.commandBar?.intent == .commandSearch ? nil : model.pasteKind?.title },
                    onPasteAndGo: { model.pasteAndGo() })
                .frame(height: min(inputHeight, layout.maximumInputHeight))
                Button {
                    model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .browserKeyboardFocus(cornerRadius: 4)
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
            if hasResults {
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
            if model.tintsChrome, contrast != .increased {
                BrowserChromeBackground(theme: model.chromeTheme,
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: totalRows)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.unavailable)
        .task(id: model.coordinator.commandBarFocusRequest) { model.refreshSuggestions() }
        .onDisappear { model.cancelCommandBarQueries(); model.commandBarIsComposing = false }
        .onChange(of: model.coordinator.commandBar?.query) { _, _ in hoveredItem = nil; hoverLocation = nil }
        .onChange(of: model.visibleCommandResults) { _, _ in hoveredItem = nil; hoverLocation = nil }
        .onChange(of: model.suggestions.results) { _, _ in hoveredItem = nil; hoverLocation = nil }
        .onExitCommand {
            guard !model.commandBarIsComposing else { return }
            model.perform(.dismissCommandBar(restoreFocus: true), source: .commandBar)
        }
        .browserReducedMotion()
    }

    private var suggestionList: some View {
        let local = model.visibleCommandResults
        let suggestions = model.suggestions.results
        let selectedLocalID = model.selectedCommandResult?.id
        let hasKeyboardSelection = selectedLocalID != nil || model.suggestions.selectedIndex != nil
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(local.enumerated()), id: \.element.id) { index, result in
                        let rowID = "result.\(result.id)"
                        let selected = selectedLocalID == result.id
                        Button { model.perform(result, source: .commandBar) } label: {
                            HStack(spacing: 10) {
                                resultIcon(for: result.candidate)
                                Text(result.candidate.title).lineLimit(1).truncationMode(.tail)
                                if let detail = result.candidate.detail {
                                    Text(CommandSearchText.address(detail))
                                        .font(.callout).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Text(resultBadge(for: result.candidate))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .font(.body)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .modifier(rowHighlight(selected: selected, hovered: !hasKeyboardSelection && hoveredItem == rowID))
                        }
                        .buttonStyle(.plain)
                        .browserKeyboardFocus()
                        .disabled(model.commandSearch.isRefreshing)
                        .opacity(model.commandSearch.isRefreshing ? 0.75 : 1)
                        .accessibilityLabel(resultAccessibilityLabel(for: result.candidate))
                        .accessibilityIdentifier("commandBar.result.\(index)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .onContinuousHover { phase in
                            updateHover(phase, rowID: rowID)
                        }
                        .id(rowID)
                    }
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        let rowID = "suggestion.\(index)"
                        let selected = model.suggestions.selectedIndex == index
                        Button { model.perform(.submit(searchSuggestion: suggestion), source: .commandBar) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                    .frame(width: 16, height: 16)
                                Text(suggestion).lineLimit(1).truncationMode(.tail)
                                    .contentTransition(.opacity)
                                Spacer(minLength: 0)
                            }
                            .font(.body)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .modifier(rowHighlight(selected: selected, hovered: !hasKeyboardSelection && hoveredItem == rowID))
                        }
                        .buttonStyle(.plain)
                        .browserKeyboardFocus()
                        .disabled(model.suggestions.isRefreshing)
                        .opacity(model.suggestions.isRefreshing ? 0.75 : 1)
                        .accessibilityLabel("Search \(model.preferences.searchEngine.name) for \(suggestion)")
                        .accessibilityIdentifier("commandBar.suggestion.\(index)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .onContinuousHover { phase in
                            updateHover(phase, rowID: rowID)
                        }
                        .id(rowID)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.commandSearch.isRefreshing)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.suggestions.isRefreshing)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: local)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: suggestions)
            .frame(height: min(layout.suggestionHeight(inputHeight: inputHeight), CGFloat(max(0, totalRows * 36 - 2))))
            .onChange(of: selectedLocalID) { _, id in
                if let id {
                    hoveredItem = nil
                    proxy.scrollTo("result.\(id)")
                }
            }
            .onChange(of: model.suggestions.selectedIndex) { _, index in
                if let index {
                    hoveredItem = nil
                    proxy.scrollTo("suggestion.\(index)")
                }
            }
        }
        .accessibilityIdentifier("commandBar.suggestions")
    }

    /// Ignore a stationary cursor when results appear under it; only highlight
    /// a hovered row after the pointer actually moves, and yield to keyboard selection.
    private func updateHover(_ phase: HoverPhase, rowID: String) {
        switch phase {
        case .active(let location):
            if let previous = hoverLocation {
                if hypot(location.x - previous.x, location.y - previous.y) >= 1 {
                    hoverLocation = location
                    hoveredItem = rowID
                }
            } else {
                hoverLocation = location
            }
        case .ended:
            if hoveredItem == rowID { hoveredItem = nil }
            hoverLocation = nil
        }
    }

    @ViewBuilder
    private func resultIcon(for candidate: CommandSearchCandidate) -> some View {
        let iconURL = resultIconURL(for: candidate)
        Group {
            if let iconURL, let image = model.webViews.favicons.image(for: iconURL) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: resultSymbol(for: candidate))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .task(id: iconURL) {
            if let iconURL { model.webViews.favicons.request(iconURL) }
        }
    }

    private func resultIconURL(for candidate: CommandSearchCandidate) -> URL? {
        guard candidate.kind.isTab || candidate.kind == .history else { return nil }
        if case .tab(let id) = candidate.target, let tab = model.coordinator.tabStore.tab(id: id) {
            return tab.pinnedURL ?? tab.currentURL
        }
        return candidate.detail.flatMap(URL.init(string:))
    }

    private func resultSymbol(for candidate: CommandSearchCandidate) -> String {
        switch candidate.kind {
        case .favorite: return "star.fill"
        case .pinnedTab: return "pin"
        case .openTab: return "globe"
        case .history: return "clock.arrow.circlepath"
        case .space: return "square.grid.2x2"
        case .profile: return "person.crop.circle"
        case .action:
            guard case .action(let action) = candidate.target else { return "command" }
            switch action {
            case .closeActiveTab, .closeTab: return "xmark"
            case .reopenLastTab: return "arrow.uturn.backward"
            case .copyCurrentURL: return "link"
            case .reload: return "arrow.clockwise"
            case .stop: return "xmark.octagon"
            case .back: return "chevron.left"
            case .forward: return "chevron.right"
            case .toggleSidebar: return "sidebar.left"
            case .newSpace: return "plus.square.on.square"
            case .openSettings: return "gearshape"
            case .setPinned(_, let pinned): return pinned ? "pin" : "pin.slash"
            case .setFavorite(_, let favorite): return favorite ? "star" : "star.slash"
            case .setMuted(_, let muted): return muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
            case .resetPinnedTab: return "arrow.counterclockwise"
            case .requestRename: return "pencil"
            case .duplicateTab: return "plus.square.on.square"
            case .openTabInNewWindow: return "macwindow.badge.plus"
            case .moveTab: return "arrow.right.square"
            case .showDownloads: return "arrow.down.circle"
            case .openFile: return "doc"
            case .printPage: return "printer"
            case .savePage: return "square.and.arrow.down"
            case .exportPDF: return "doc.richtext"
            default: return "command"
            }
        }
    }

    private func resultBadge(for candidate: CommandSearchCandidate) -> String {
        model.commandResultBadge(for: candidate)
    }

    private func resultAccessibilityLabel(for candidate: CommandSearchCandidate) -> String {
        if candidate.kind == .action {
            return candidate.title
        }
        return "\(resultBadge(for: candidate)): \(candidate.title)"
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

/// A command-bar row's selection and hover.
struct CommandRowHighlight: ViewModifier {
    let selected: Bool
    let hovered: Bool
    /// The Space's color; nil keeps the neutral gray.
    let tint: Color?
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        let color = tint ?? .primary
        let fill = tint == nil ? (selected || hovered ? 0.08 : 0) : (selected ? 0.20 : (hovered ? 0.10 : 0))
        let edge = selected ? (increasedContrast ? 1 : (tint == nil ? 0.35 : 0.6)) : 0
        content
            .background(color.opacity(fill), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(color.opacity(edge), lineWidth: increasedContrast ? 2 : 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}
