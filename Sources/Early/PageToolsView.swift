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
            if let phase = model.webViews.pages[tabID]?.translation {
                TranslationBadge(model: model, tabID: tabID, phase: phase)
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

/// Shown while a pane is in Reader: a clear way back to the original page.
struct ReaderBadge: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        HStack(spacing: 8) {
            Label("Reader", systemImage: "doc.plaintext")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Button("Show Original") { model.toggleReader(tabID) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .browserKeyboardFocus(cornerRadius: 5)
                .help("Return to the original page (Command-Shift-R)")
                .accessibilityIdentifier("reader.original")
        }
        .padding(.horizontal, 10).frame(height: 30)
        .modifier(PageToolSurface(theme: model.splitTheme, allowsTransparency: model.preferences.translucentChrome))
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.badge")
    }
}

/// Original Early artwork for site controls: two sliders in a rounded square,
/// on the same 24-point grid and stroke as the download icon.
struct SiteControlsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 4.5, height: 4.5))
        // Each slider's track stops short of its knob instead of crossing it.
        for (y, knob) in [(9.5, 10.0), (14.5, 14.0)] {
            path.move(to: CGPoint(x: 7, y: y))
            path.addLine(to: CGPoint(x: knob - 1.9, y: y))
            path.move(to: CGPoint(x: knob + 1.9, y: y))
            path.addLine(to: CGPoint(x: 17, y: y))
            path.addEllipse(in: CGRect(x: knob - 1.9, y: y - 1.9, width: 3.8, height: 3.8))
        }
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                               tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale))
    }
}

/// The address pill's only icon. Its panel gathers the current page's working
/// controls: Copy Link, Reader, Translate and Zoom.
struct SiteControlsButton: View {
    @Bindable var model: BrowserWindowModel
    @State private var presented = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static func isVisible(for model: BrowserWindowModel) -> Bool { model.currentPageURL != nil }

    /// Reader or a translation is on: the icon takes the theme color.
    static func isActive(_ page: BrowserPage?) -> Bool {
        page?.isReaderShown == true || page?.translation.isActive == true
    }

    var body: some View {
        let tint = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        if Self.isVisible(for: model), let id = model.coordinator.focusedTabID {
            Button { presented.toggle() } label: {
                SiteControlsGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Self.isActive(model.activePage) ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .browserKeyboardFocus(cornerRadius: 6)
            .help("Site Controls")
            .accessibilityLabel("Site Controls")
            .accessibilityIdentifier("address.siteControls")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                SiteControlsPanel(model: model, tabID: id) { presented = false }
            }
        }
    }
}

struct SiteControlsPanel: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static func readerValue(_ page: BrowserPage) -> String { page.isReaderShown ? "On" : "Off" }

    static func translationValue(_ page: BrowserPage, title: String) -> String {
        switch page.translation {
        case .translating: return "Translating…"
        case .translated: return "Translated"
        case .original, .failed: return title.replacingOccurrences(of: "Translate ", with: "").capitalizedFirst
        }
    }

    var body: some View {
        let tint = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        let page = model.webViews.pages[tabID]
        let url = model.currentPageURL
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.host ?? url?.lastPathComponent ?? "Page").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(url?.absoluteString ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let page {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    if page.isReaderShown || page.isReaderAvailable {
                        SiteControlRow(symbol: "doc.plaintext", title: "Reader", value: Self.readerValue(page),
                                       active: page.isReaderShown, tint: tint, identifier: "siteControls.reader") {
                            model.perform(.toggleReader)
                            dismiss()
                        }
                        .disabled(!model.canPerform(.toggleReader))
                    }
                    if let title = model.translationTitle(for: tabID) {
                        SiteControlRow(symbol: "translate", title: "Translate", value: Self.translationValue(page, title: title),
                                       active: page.translation.isActive, tint: tint, identifier: "siteControls.translate") {
                            model.perform(.toggleTranslation)
                            dismiss()
                        }
                    }
                    SiteControlRow(symbol: "plus.magnifyingglass", title: "Zoom", value: ZoomNoticeView.text(for: page.zoom),
                                   active: page.zoom != 1, tint: tint, identifier: "siteControls.zoomReset") {
                        model.perform(.resetZoom)
                    } trailing: {
                        HStack(spacing: 4) {
                            zoomButton("minus", "Zoom Out", .zoomOut, identifier: "siteControls.zoomOut")
                            zoomButton("plus", "Zoom In", .zoomIn, identifier: "siteControls.zoomIn")
                        }
                    }
                    .help(page.zoom == 1 ? "Actual size" : "Return to actual size (Command-0)")
                }
            }
            Divider()
            Button {
                model.perform(.copyCurrentURL)
                dismiss()
            } label: {
                Label("Copy Link", systemImage: "link")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .browserKeyboardFocus(cornerRadius: 8)
            .disabled(!model.canPerform(.copyCurrentURL))
            .help("Copy Current URL (Command-Shift-C)")
            .accessibilityIdentifier("siteControls.copyLink")
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteControls.panel")
    }

    private func zoomButton(_ symbol: String, _ label: String, _ action: BrowserAction, identifier: String) -> some View {
        Button { model.perform(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .browserKeyboardFocus(cornerRadius: 13)
        .disabled(!model.canPerform(action))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// One control in the site panel: a round icon, a title and its current value.
struct SiteControlRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let value: String
    let active: Bool
    let tint: Color
    let identifier: String
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, title: String, value: String, active: Bool, tint: Color, identifier: String,
         action: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.value = value
        self.active = active
        self.tint = tint
        self.identifier = identifier
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 32)
                        .background(active ? tint.opacity(0.18) : Color.primary.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .browserKeyboardFocus(cornerRadius: 8)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
