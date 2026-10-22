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
