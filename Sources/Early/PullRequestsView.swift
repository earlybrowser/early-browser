// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// The Pull Requests live folder in a Space's sidebar: the profile's open
/// pull requests on GitHub, read with the GitHub sign-in it already has.
/// Choosing one opens it in a Today tab; nothing loads until then.
struct PullRequestsFolder: View {
    @Bindable var model: BrowserWindowModel
    let space: BrowserSpace
    let feed: PullRequestFeed
    let themeColor: BrowserSpace.Color
    @State private var hovered: String?
    @Environment(\.colorSchemeContrast) private var contrast

    private var isOpen: Bool { model.openPullRequestFolders.contains(space.id) }

    /// What the folder says instead of a list.
    static func message(for status: PullRequestFolderStatus, isEmpty: Bool) -> (text: String, symbol: String)? {
        switch status {
        case .idle, .loading: ("Reading GitHub…", "arrow.triangle.pull")
        case .ready: isEmpty ? ("No open pull requests", "checkmark.circle") : nil
        case .signedOut: ("Sign in to GitHub", "person.crop.circle.badge.plus")
        case .offline: ("Can’t reach GitHub", "wifi.slash")
        case .throttled: ("GitHub asked Early to wait; it will try again later", "hourglass")
        case .unreadable: ("Couldn’t read GitHub’s pull requests", "exclamationmark.triangle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if isOpen {
                contents.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .contextMenu { folderMenu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pullRequests.folder.\(space.id)")
    }

    private var header: some View {
        Button { model.togglePullRequestsFolder(in: space.id) } label: {
            HStack(spacing: 4) {
                FolderIcon(isOpen: isOpen, themeColor: themeColor)
                    .frame(width: 19, height: 20)
                    .frame(width: 24, height: 34)
                    .accessibilityHidden(true)
                Text("Pull Requests").lineLimit(1)
                Spacer(minLength: 0)
                if feed.isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing")
                } else if !isOpen, feed.count > 0 {
                    Text("\(feed.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(fill(hovered == "header"), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 ? "header" : (hovered == "header" ? nil : hovered) }
        .browserKeyboardFocus(cornerRadius: 10)
        .help("Your open pull requests on GitHub, read with the GitHub account you’re signed in to in this profile")
        .accessibilityLabel("Pull Requests")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("pullRequests.toggle")
    }

    @ViewBuilder private var contents: some View {
        let shown = feed.sections.filter { !$0.items.isEmpty }
        if let message = Self.message(for: feed.status, isEmpty: shown.isEmpty) {
            messageRow(message.text, symbol: message.symbol)
        } else {
            ForEach(shown) { section in
                Text(section.group.title.uppercased())
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 32).padding(.top, 6).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.items) { row($0) }
            }
        }
    }

    private func row(_ pullRequest: PullRequest) -> some View {
        let selected = model.currentPageURL.map { pullRequest.isShown(at: $0) } ?? false
        return Button { model.openPullRequest(pullRequest) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pullRequest.title).lineLimit(1)
                    Text("\(pullRequest.repositoryName) #\(pullRequest.number)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(fill(hovered == pullRequest.id, selected: selected), in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 ? pullRequest.id : (hovered == pullRequest.id ? nil : hovered) }
        .browserKeyboardFocus(cornerRadius: 7)
        .help("\(pullRequest.title)\n\(pullRequest.url().absoluteString)")
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url().absoluteString, forType: .string)
            }
            Divider()
            folderMenu
        }
        .accessibilityLabel("\(pullRequest.title), \(pullRequest.repositoryName) number \(pullRequest.number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("pullRequests.item.\(pullRequest.id)")
    }

    @ViewBuilder private func messageRow(_ text: String, symbol: String) -> some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
        switch feed.status {
        case .signedOut:
            // Signing in happens on GitHub, in a tab; Early never sees it.
            Button { _ = model.openLocations([PullRequest.github.appending(path: "login")]) } label: {
                label.foregroundStyle(.primary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(fill(hovered == "message"), in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 ? "message" : nil }
            .browserKeyboardFocus(cornerRadius: 7)
            .help("Open GitHub’s sign-in page in a new tab")
            .accessibilityIdentifier("pullRequests.signIn")
        case .offline, .unreadable:
            Button { feed.refresh() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .background(fill(hovered == "message"), in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovered = $0 ? "message" : nil }
                .browserKeyboardFocus(cornerRadius: 7)
                .help("Try Again")
                .accessibilityHint("Try again")
                .accessibilityIdentifier("pullRequests.message")
        default:
            label.accessibilityElement(children: .combine).accessibilityIdentifier("pullRequests.message")
        }
    }

    @ViewBuilder private var folderMenu: some View {
        Button("Refresh") { feed.refresh() }
            .disabled(feed.isRefreshing)
        Button("Open Pull Requests on GitHub") { _ = model.openLocations([PullRequest.github.appending(path: "pulls")]) }
        Divider()
        Button("Remove Folder") { model.setPullRequestsFolder(false, in: space.id) }
    }

    private func fill(_ hovered: Bool, selected: Bool = false) -> Color {
        Color.primary.opacity(selected ? (contrast == .increased ? 0.18 : 0.08) : (hovered ? 0.04 : 0))
    }
}
