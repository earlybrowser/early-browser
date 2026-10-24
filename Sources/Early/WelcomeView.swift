// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

/// The first window's welcome, below the command bar: what's where, in a few
/// lines. It never takes the command bar's focus, and nothing opens until the
/// person chooses.
struct WelcomeCard: View {
    @Bindable var model: BrowserWindowModel
    /// Only the title and buttons, for a short window.
    var compact = false
    @State private var asking = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    struct Tip: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static func tips(_ shortcuts: BrowserShortcuts) -> [Tip] {
        let newTab = shortcuts.shortcut(for: .newTab).map { " (\($0.display))" } ?? ""
        let location = shortcuts.shortcut(for: .openLocation).map { " (\($0.display))" } ?? ""
        return [
            Tip(symbol: "command", title: "Search or go anywhere",
                detail: "The command bar opens a new tab\(newTab) or changes the page you’re on\(location)."),
            Tip(symbol: "sidebar.left", title: "Favorites, pins and Today",
                detail: "Favorites sit at the top, pins keep their place, and Today holds everything else."),
            Tip(symbol: "smallcircle.filled.circle", title: "Spaces",
                detail: "The dots under the sidebar are your Spaces; the ringed one is where you are. + adds one."),
            Tip(symbol: "rectangle.split.2x1", title: "Two pages at once",
                detail: "Right-click a tab and choose Split View. The address bar follows the side you’re using."),
            Tip(symbol: "rectangle.stack", title: "Recent tabs",
                detail: "Hold Control and press Tab to see your recent tabs, then let go to switch."),
            Tip(symbol: "arrow.down.circle", title: "Downloads",
                detail: "Your downloads are a click away, at the bottom left of the sidebar."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Welcome to Early").font(.title3.weight(.semibold))
                Spacer()
                Button { model.finishWelcome() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .browserKeyboardFocus(cornerRadius: 6)
                .help("Close")
                .accessibilityLabel("Close Welcome")
                .accessibilityIdentifier("welcome.close")
            }
            if !compact {
                Grid(alignment: .topLeading, horizontalSpacing: 22, verticalSpacing: 14) {
                    let tips = Self.tips(model.preferences.shortcuts)
                    ForEach(0..<(tips.count + 1) / 2, id: \.self) { row in
                        GridRow {
                            tip(tips[row * 2])
                            if row * 2 + 1 < tips.count { tip(tips[row * 2 + 1]) }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                if let application = model.application, !application.isDefaultBrowser {
                    Button("Make Early Your Default Browser…") {
                        asking = true
                        Task {
                            await application.makeDefaultBrowser()
                            asking = false
                        }
                    }
                    .disabled(asking)
                    .accessibilityIdentifier("welcome.makeDefault")
                }
                Spacer()
                // No Escape shortcut: Escape belongs to the command bar.
                Button("Get Started") { model.finishWelcome() }
                    .accessibilityIdentifier("welcome.done")
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14)
            if reduceTransparency || contrast == .increased { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            else { shape.fill(.regularMaterial) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.08))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Early")
        .accessibilityIdentifier("welcome")
    }

    private func tip(_ tip: Tip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: tip.symbol).foregroundStyle(.secondary).frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title).font(.callout.weight(.medium))
                Text(tip.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
