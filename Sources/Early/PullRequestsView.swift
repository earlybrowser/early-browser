// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// What a GitHub live folder says below its pins: while it reads GitHub, when
/// there's nothing to show, or why it can't read. Its pins are ordinary
/// pinned tabs; this row is only a note.
struct LiveFolderStatusRow: View {
    @Bindable var model: BrowserWindowModel
    let feed: PullRequestFeed
    let hasPins: Bool
    @State private var hovered = false

    /// Nil when the pins say it all.
    static func message(for status: PullRequestFolderStatus, hasPins: Bool) -> (text: String, symbol: String)? {
        switch status {
        case .idle, .loading: hasPins ? nil : ("Reading GitHub…", "arrow.triangle.pull")
        case .ready: hasPins ? nil : ("No open pull requests", "checkmark.circle")
        case .signedOut: ("Sign in to GitHub", "person.crop.circle.badge.plus")
        case .offline: ("Can’t reach GitHub", "wifi.slash")
        case .throttled: ("GitHub asked Early to wait; it will try again later", "hourglass")
        case .unreadable: ("Couldn’t read GitHub’s pull requests", "exclamationmark.triangle")
        }
    }

    var body: some View {
        if let message = Self.message(for: feed.status, hasPins: hasPins) {
            let label = HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: message.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                    .accessibilityHidden(true)
                Text(message.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            switch feed.status {
            case .signedOut:
                // Signing in happens on GitHub, in a tab; Early never sees it.
                action(label.foregroundStyle(.primary), help: "Open GitHub’s sign-in page in a new tab",
                       identifier: "liveFolder.signIn") {
                    _ = model.openLocations([PullRequest.github.appending(path: "login")])
                }
            case .offline, .unreadable:
                action(label.foregroundStyle(.secondary), help: "Try Again", identifier: "liveFolder.message") { feed.refresh() }
            default:
                label.foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("liveFolder.message")
            }
        }
    }

    private func action(_ label: some View, help: String, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { label }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(hovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .browserKeyboardFocus(cornerRadius: 7)
            .help(help)
            .accessibilityIdentifier(identifier)
    }
}
