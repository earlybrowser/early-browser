// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// The shared look of a pane's floating tools: the active Space's chrome with
/// a theme-colored edge, like the split drop cards.
struct PageToolSurface: ViewModifier {
    let theme: BrowserSpace.Color
    let allowsTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background {
                BrowserChromeBackground(spaceColor: theme, floating: true, allowsTransparency: allowsTransparency)
                    .clipShape(Self.shape)
            }
            .overlay {
                Self.shape
                    .strokeBorder(theme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
                        .opacity(contrast == .increased ? 1 : 0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 10, y: 3)
    }
}

/// Floating tools at the top trailing corner of one pane.
struct PageToolsOverlay: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let find = model.webViews.pages[tabID]?.find {
                PageFindBar(model: model, tabID: tabID, state: find)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            if let notice = model.zoomNotice, notice.tabID == tabID {
                ZoomNoticeView(zoom: notice.zoom, theme: model.splitTheme,
                               allowsTransparency: model.preferences.translucentChrome)
                    .task(id: notice.id) {
                        do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                        if model.zoomNotice?.id == notice.id { model.zoomNotice = nil }
                    }
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.zoomNotice?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.webViews.pages[tabID]?.find != nil)
    }
}

/// The hovered link's address, like Safari's status bar. Drawing only: the
/// page keeps every click, and the preview hides while the page is fullscreen.
struct LinkPreview: View {
    let hover: LinkHover
    let theme: BrowserSpace.Color
    let allowsTransparency: Bool

    var body: some View {
        Text(hover.url.absoluteString)
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(PageToolSurface(theme: theme, allowsTransparency: allowsTransparency))
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityLabel("Link address")
            .accessibilityValue(hover.url.absoluteString)
            .accessibilityIdentifier("page.linkPreview")
    }
}

/// Find on page for one pane: live results as you type, Return/Shift-Return
/// for next/previous, Escape to close and return focus to the page.
struct PageFindBar: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    let state: PageFindState
    @State private var text: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: BrowserWindowModel, tabID: UUID, state: PageFindState) {
        self.model = model
        self.tabID = tabID
        self.state = state
        _text = State(initialValue: state.query)
    }

    static func status(for state: PageFindState) -> String {
        guard !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard state.matchCount > 0 else { return state.isSearching ? "" : "No matches" }
        return "\((state.currentIndex ?? 0) + 1) of \(state.matchCount)\(state.isCapped ? "+" : "")"
    }

    var body: some View {
        let tint = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        let status = Self.status(for: state)
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.leading, 2)
                .accessibilityHidden(true)
            TextField("Find on Page", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 160)
                .focused($fieldFocused)
                .onSubmit { step(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { model.closeFind(tabID) }
                .accessibilityLabel("Find on page")
                .accessibilityValue(status)
                .accessibilityIdentifier("find.field")
            Text(status)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("find.status")
            Divider().frame(height: 16).padding(.horizontal, 2)
            control("chevron.up", "Previous Match (Command-Shift-G)", identifier: "find.previous") { step(backwards: true) }
                .disabled(state.matchCount == 0)
            control("chevron.down", "Next Match (Command-G)", identifier: "find.next") { step(backwards: false) }
                .disabled(state.matchCount == 0)
            control("xmark", "Close Find (Escape)", identifier: "find.close") { model.closeFind(tabID) }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .modifier(PageToolSurface(theme: model.splitTheme, allowsTransparency: model.preferences.translucentChrome))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on page")
        .accessibilityIdentifier("find.bar")
        .task(id: text) {
            // Search as you type, after a short pause, without redoing the
            // search a Use Selection or reopened bar already started.
            guard text != model.webViews.pages[tabID]?.find?.query else { return }
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            model.webViews.updateFind(tabID, query: text)
        }
        .onChange(of: state.query) { _, query in if query != text { text = query } }
        .onChange(of: model.findFocusRequest) { focusField() }
        .onAppear { focusField() }
    }

    private func step(backwards: Bool) {
        // Return before the typing pause still shows the first match first.
        if text != state.query { model.webViews.updateFind(tabID, query: text) }
        else { model.webViews.findNext(tabID, backwards: backwards) }
    }

    private func focusField() {
        guard model.coordinator.focusedTabID == tabID else { return }
        DispatchQueue.main.async {
            fieldFocused = true
            // Command-F on an open bar selects the search to replace it.
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    private func control(_ symbol: String, _ help: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .browserKeyboardFocus(cornerRadius: 5)
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
        .accessibilityIdentifier(identifier)
    }
}

struct ZoomNoticeView: View {
    let zoom: Double
    let theme: BrowserSpace.Color
    let allowsTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static func text(for zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    var body: some View {
        Label(Self.text(for: zoom), systemImage: "plus.magnifyingglass")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .labelStyle(ZoomLabelStyle(tint: theme.focusBorder(isDark: colorScheme == .dark,
                                                              increasedContrast: contrast == .increased).color))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .modifier(PageToolSurface(theme: theme, allowsTransparency: allowsTransparency))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom \(Self.text(for: zoom))")
            .accessibilityIdentifier("page.zoomNotice")
    }

    private struct ZoomLabelStyle: LabelStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.foregroundStyle(tint)
                configuration.title
            }
        }
    }
}

/// Command-= zooms in like Command-+ (the menu shows the shifted key). Other
/// keys, and every key while text is being composed, pass through untouched.
struct PageShortcutMonitor: NSViewRepresentable {
    let model: BrowserWindowModel
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    static func isZoomIn(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        characters == "=" && modifiers.intersection([.command, .shift, .option, .control]) == .command
    }

    final class MonitorView: NSView {
        weak var model: BrowserWindowModel?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil,
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                      PageShortcutMonitor.isZoomIn(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                      self.model?.perform(.zoomIn) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
