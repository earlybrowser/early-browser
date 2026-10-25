// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// The window's top controls: New Tab, Back, Forward, Reload and the address bar.
extension BrowserWindowView {
    var newTabButton: some View {
        Button {
            model.perform(.presentCommandBar(.newTab))
        } label: {
            HStack {
                Label("New Tab", systemImage: "plus")
                Spacer()
                if let shortcut = model.preferences.shortcuts.shortcut(for: .newTab) {
                    Text(shortcut.display).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .browserKeyboardFocus()
        .accessibilityIdentifier("sidebar.newTab")
        .help("Open the command bar\(model.preferences.shortcutHint(.newTab))")
    }

    var navigationControls: some View {
        HStack(spacing: 4) {
            WindowControls().frame(width: 60, height: 32)
            Button {
                model.perform(.toggleSidebar)
                sidebarHovered = false
            } label: {
                Image(systemName: "sidebar.left").frame(width: 32, height: 32)
            }
            .browserKeyboardFocus(cornerRadius: 8)
            .accessibilityLabel(sidebarAutoHides ? "Keep sidebar visible" : "Auto-hide sidebar")
            .accessibilityValue(sidebarAutoHides ? "Auto-hide enabled" : "Always visible")
            .keyboardShortcut(model.preferences.keyboardShortcut(.toggleSidebar))
            .accessibilityIdentifier("sidebar.toggle")
            .help("Toggle sidebar auto-hide\(model.preferences.shortcutHint(.toggleSidebar)). Reveal at the left edge.")
            Spacer(minLength: 0)
            NavigationButton(kind: .back, history: { historyEntries(forward: false) },
                             onHistory: { model.perform(.goToHistory(offset: $0)) }) { model.perform(.back) }
                .disabled(model.activePage?.canGoBack != true)
                .accessibilityLabel("Back").accessibilityIdentifier("navigation.back")
            NavigationButton(kind: .forward, history: { historyEntries(forward: true) },
                             onHistory: { model.perform(.goToHistory(offset: $0)) }) { model.perform(.forward) }
                .disabled(model.activePage?.canGoForward != true)
                .accessibilityLabel("Forward").accessibilityIdentifier("navigation.forward")
            NavigationButton(kind: model.activePage?.isLoading == true ? .stop : .reload) {
                if model.activePage?.isLoading == true { model.perform(.stop) }
                else { model.perform(.reload) }
            }
            .disabled(model.activePage == nil)
            .accessibilityLabel(model.activePage?.isLoading == true ? "Stop Loading" : "Reload")
            .accessibilityIdentifier(model.activePage?.isLoading == true ? "navigation.stop" : "navigation.reload")
        }
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .background(WindowDragRegion())
        // Match the traffic lights' top inset: 6 pt of window padding plus
        // 9 pt from centering the native 14 pt buttons in this 32 pt row.
        .padding(.leading, 7)
    }

    func historyEntries(forward: Bool) -> [WebViewManager.HistoryListEntry] {
        model.coordinator.focusedTabID.map { model.webViews.historyList($0, forward: forward) } ?? []
    }

    var currentURL: String? {
        guard case .web(let id) = model.coordinator.content else { return nil }
        return model.coordinator.tabStore.tab(id: id)?.currentURL.absoluteString
    }

    var addressBar: some View {
        Button {
            model.perform(.presentCommandBar(.navigateCurrentTab))
        } label: {
            HStack(spacing: 8) {
                if currentURL == nil {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if let security = model.activePage?.security, security.isInsecure {
                    Image(systemName: SiteSecurityRow.symbol(security))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help(SiteSecurityRow.title(security))
                        .accessibilityHidden(true)
                }
                Text(addressLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(currentURL == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if SiteControlsButton.isVisible(for: model) {
                    // Room for the site controls drawn over this trailing edge.
                    Color.clear.frame(width: 22, height: 1)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .background(Color.primary.opacity(contrast == .increased ? 0.12 : (addressHovered ? 0.085 : 0.055)),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                BrowserFocusOutline(focused: focusedSidebarControl == .address, cornerRadius: 12)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focused($focusedSidebarControl, equals: .address)
        .focusEffectDisabled()
        .onHover { hovering in
            addressHovered = hovering
            // A right-click always follows the pointer here: name the item first.
            if hovering { model.refreshPasteKind() }
        }
        .onAppear { model.refreshPasteKind() }
        .contextMenu {
            if let kind = model.pasteKind {
                Button(kind.title) { model.pasteAndGo(.navigateCurrentTab) }
                    .disabled(!model.canPerform(.presentCommandBar(.navigateCurrentTab)))
            }
            Button("Copy Current URL") { model.perform(.copyCurrentURL) }
                .disabled(!model.canPerform(.copyCurrentURL))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: addressHovered)
        .accessibilityLabel("Address bar")
        .accessibilityValue(currentURL ?? "No active tab")
        .accessibilityHint(model.activePage?.security.isInsecure == true ? SiteSecurityRow.title(model.activePage?.security ?? .none) : "")
        .accessibilityIdentifier("sidebar.addressBar")
        .help(currentURL.map { "\($0) — Open Location\(model.preferences.shortcutHint(.openLocation))" }
              ?? "Search or enter a URL\(model.preferences.shortcutHint(.openLocation))")
        // Its own controls, outside the pill's single accessibility element.
        .overlay(alignment: .trailing) { SiteControlsButton(model: model).padding(.trailing, 5) }
    }

    var addressLabel: String {
        guard let currentURL, let address = URL(string: currentURL) else { return "Search…" }
        let source = NavigationInput.page(ofSource: address)
        guard let url = source ?? Optional(address), let host = url.host else { return "Search…" }
        if source != nil { return NavigationInput.pageSourceScheme + ":" + host }
        // Keep the complete URL in the editor, accessibility value and hover help.
        return (url.scheme == "http" ? "http://" : "") + host
            + (url.port.map { ":\($0)" } ?? "")
    }
}
