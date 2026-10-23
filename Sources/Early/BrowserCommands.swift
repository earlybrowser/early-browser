// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

private struct BrowserWindowKey: FocusedValueKey {
    typealias Value = BrowserWindowModel
}

extension FocusedValues {
    var browserWindow: BrowserWindowModel? {
        get { self[BrowserWindowKey.self] }
        set { self[BrowserWindowKey.self] = newValue }
    }
}

struct BrowserCommands: Commands {
    let application: EarlyAppDelegate
    @FocusedValue(\.browserWindow) private var model
    @Environment(\.openSettings) private var openSettings

    static let recentlyClosedTabLimit = 10

    /// Page titles stay short enough for a menu.
    static func menuTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 60 ? String(line.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Menus draw an item's image at the image's own size.
    static let menuIconSize = NSSize(width: 16, height: 16)

    static func menuIcon(_ image: NSImage) -> NSImage {
        let icon = (image.copy() as? NSImage) ?? image
        icon.size = menuIconSize
        return icon
    }

    /// A page in History's menu: its site icon, or a globe until one is known.
    private func pageItem(_ title: String, url: URL, model: BrowserWindowModel) -> some View {
        Label {
            Text(Self.menuTitle(title))
        } icon: {
            if let icon = model.webViews.favicons.image(for: url) {
                Image(nsImage: Self.menuIcon(icon))
            } else {
                Image(systemName: "globe")
            }
        }
        .labelStyle(.titleAndIcon)
    }

    // Older SDKs' command builders take at most ten items (CI's Xcode 26.6),
    // so the menu bar comes in two parts.
    var body: some Commands {
        applicationCommands
        browsingMenus
    }

    @CommandsBuilder private var applicationCommands: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Passwords…") {
                if let model, model.perform(.showPasswords) { return }
                application.showPasswords(profileID: nil)
            }
            .disabled(application.workspace == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                if let model { _ = model.perform(.newWindow) }
                else { _ = application.openNewWindow() }
            }
            .keyboardShortcut("n")
            .disabled(model.map { !$0.canPerform(.newWindow) } ?? !application.canOpenWindow)
            Button("New Private Window") {
                if let model { _ = model.perform(.newPrivateWindow) }
                else { _ = application.openPrivateWindow() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.map { !$0.canPerform(.newPrivateWindow) } ?? !application.canOpenWindow)
            Button("New Tab") { model?.perform(.presentCommandBar(.newTab)) }
                .keyboardShortcut("t")
                .disabled(model?.canPerform(.presentCommandBar(.newTab)) != true)
            Button("Open Location…") { model?.perform(.presentCommandBar(.navigateCurrentTab)) }
                .keyboardShortcut("l")
                .disabled(model?.canPerform(.presentCommandBar(.navigateCurrentTab)) != true)
            Button("Open File…") { model?.perform(.openFile) }
                .keyboardShortcut("o")
                .disabled(model?.canPerform(.openFile) != true)
        }
        CommandGroup(replacing: .saveItem) {
            Button(model == nil ? "Close Window" : "Close Tab") {
                if let model {
                    model.perform(.closeActiveTab)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Save Page As…") { model?.perform(.savePage) }
                .keyboardShortcut("s")
                .disabled(model?.canPerform(.savePage) != true)
            Button("Export as PDF…") { model?.perform(.exportPDF) }
                .disabled(model?.canPerform(.exportPDF) != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { model?.perform(.find) }
                    .keyboardShortcut("f")
                    .disabled(model?.canPerform(.find) != true)
                Button("Find Next") { model?.perform(.findNext) }
                    .keyboardShortcut("g")
                    .disabled(model?.canPerform(.findNext) != true)
                Button("Find Previous") { model?.perform(.findPrevious) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model?.canPerform(.findPrevious) != true)
                Button("Use Selection for Find") { model?.perform(.useSelectionForFind) }
                    .keyboardShortcut("e")
                    .disabled(model?.canPerform(.useSelectionForFind) != true)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.perform(.printPage) }
                .keyboardShortcut("p")
                .disabled(model?.canPerform(.printPage) != true)
        }
        CommandGroup(after: .toolbar) {
            // Command-= also zooms in; see PageShortcutMonitor.
            Button("Actual Size") { model?.perform(.resetZoom) }
                .keyboardShortcut("0")
                .disabled(model?.canPerform(.resetZoom) != true)
            Button("Zoom In") { model?.perform(.zoomIn) }
                .keyboardShortcut("+")
                .disabled(model?.canPerform(.zoomIn) != true)
            Button("Zoom Out") { model?.perform(.zoomOut) }
                .keyboardShortcut("-")
                .disabled(model?.canPerform(.zoomOut) != true)
            Divider()
            Button(model?.activePage?.isReaderShown == true ? "Hide Reader" : "Show Reader") { model?.perform(.toggleReader) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.canPerform(.toggleReader) != true)
            Button(model.flatMap { model in model.coordinator.focusedTabID.flatMap(model.translationTitle) } ?? "Translate Page") {
                model?.perform(.toggleTranslation)
            }
            .disabled(model?.canPerform(.toggleTranslation) != true)
            Divider()
            Button("View Page Source") { model?.perform(.viewPageSource) }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(model?.canPerform(.viewPageSource) != true)
            if WebViewManager.supportsWebInspector {
                Button(model?.isWebInspectorVisible == true ? "Hide Web Inspector" : "Show Web Inspector") {
                    model?.perform(.toggleWebInspector)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model?.canPerform(.toggleWebInspector) != true)
            }
            Divider()
            Button("Show Downloads") { model?.perform(.showDownloads) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model?.canPerform(.showDownloads) != true)
        }
    }

    @CommandsBuilder private var browsingMenus: some Commands {
        CommandMenu("History") {
            Button("Back") { model?.perform(.back) }.keyboardShortcut("[")
                .disabled(model?.canPerform(.back) != true)
            Button("Forward") { model?.perform(.forward) }.keyboardShortcut("]")
                .disabled(model?.canPerform(.forward) != true)
            Divider()
            Button("Show All History") { model?.perform(.showHistory) }
                .keyboardShortcut("y")
                .disabled(model?.canPerform(.showHistory) != true)
            Divider()
            Button("Reopen Closed Tab") { model?.perform(.reopenLastTab) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model?.canPerform(.reopenLastTab) != true)
            // Works with no window open, after closing the last one.
            Button("Reopen Closed Window") {
                if let model { _ = model.perform(.reopenClosedWindow) }
                else { _ = application.reopenClosedWindow() }
            }
            .disabled(model.map { !$0.canPerform(.reopenClosedWindow) } ?? !application.canReopenClosedWindow)
            Menu("Recently Closed") {
                if let model {
                    ForEach(model.recentlyClosedTabs.prefix(Self.recentlyClosedTabLimit)) { tab in
                        Button { model.perform(.reopenRecentlyClosedTab(tab.id)) } label: {
                            pageItem(tab.displayTitle, url: tab.currentURL, model: model)
                        }
                    }
                }
                if model?.recentlyClosedTabs.isEmpty == false, !application.recentlyClosedWindows.isEmpty { Divider() }
                ForEach(application.recentlyClosedWindows) { closed in
                    Button {
                        if let model { _ = model.perform(.reopenRecentlyClosedWindow(closed.id)) }
                        else { _ = application.reopenClosedWindow(closed.id) }
                    } label: {
                        Label("Window: \(Self.menuTitle(closed.title))", systemImage: "macwindow").labelStyle(.titleAndIcon)
                    }
                    .disabled(model.map { !$0.canPerform(.reopenRecentlyClosedWindow(closed.id)) } ?? !application.canReopenClosedWindow(closed.id))
                }
            }
            .disabled(model?.recentlyClosedTabs.isEmpty != false && application.recentlyClosedWindows.isEmpty)
            // Today's pages, newest first, as in Safari. Private windows list none.
            if let model, !model.recentlyVisited.isEmpty {
                Divider()
                ForEach(model.recentlyVisited, id: \.url) { page in
                    Button { model.perform(.openHistoryPage(page.url)) } label: {
                        pageItem(page.title.isEmpty ? (page.url.host ?? page.url.absoluteString) : page.title, url: page.url, model: model)
                    }
                    .disabled(!model.canPerform(.openHistoryPage(page.url)))
                }
            }
            Divider()
            Button("Clear History…") { model?.perform(.clearHistory) }
                .disabled(model?.canPerform(.clearHistory) != true)
        }
        CommandMenu("Tab") {
            Button("Next Tab") { model?.advanceTabSwitcher(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model?.canPresentTabSwitcher != true)
            Button("Previous Tab") { model?.advanceTabSwitcher(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model?.canPresentTabSwitcher != true)
            // Shortcuts in a submenu still work from anywhere, like Find's.
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") { model?.perform(.selectTabNumber(number)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))))
                        .disabled(model?.canPerform(.selectTabNumber(number)) != true)
                }
            }
            Divider()
            Button("Reload Page") { model?.perform(.reload) }.keyboardShortcut("r")
                .disabled(model?.canPerform(.reload) != true)
            Button("Stop Loading") { model?.perform(.stop) }.keyboardShortcut(".")
                .disabled(model?.canPerform(.stop) != true)
            Button("Copy Current URL") { model?.perform(.copyCurrentURL) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.canPerform(.copyCurrentURL) != true)
            Divider()
            Button("Duplicate Tab") {
                if let tab = model?.activeTab { model?.perform(.duplicateTab(tab.id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.duplicateTab($0.id)) == true } != true)
            Button("Open Tab in New Window") {
                if let tab = model?.activeTab { model?.perform(.openTabInNewWindow(tab.id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.openTabInNewWindow($0.id)) == true } != true)
            Button("Rename Tab…") {
                if let id = model?.activeTab?.id { model?.perform(.requestRename(id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.requestRename($0.id)) == true } != true)
            Button(model?.activePage?.isMuted == true ? "Unmute Tab" : "Mute Tab") {
                if let tab = model?.activeTab {
                    model?.perform(.setMuted(tab.id, model?.activePage?.isMuted != true))
                }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.setMuted($0.id, model?.activePage?.isMuted != true)) == true } != true)
            Menu("Move Tab to Space") {
                if let model, let tab = model.activeTab {
                    ForEach(model.coordinator.spaces) { space in
                        Button(space.name) { model.perform(.moveTab(tab.id, toSpace: space.id)) }
                            .disabled(!model.canPerform(.moveTab(tab.id, toSpace: space.id)))
                    }
                }
            }
            .disabled(model?.activeTab == nil || model?.activeTab?.isFavorite == true || model?.canManageSpaces != true)
            Divider()
            Button(model?.activeTab?.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                if let tab = model?.activeTab { model?.perform(.setPinned(tab.id, tab.pinnedURL == nil)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.setPinned($0.id, $0.pinnedURL == nil)) == true } != true)
            Button("Reset to Pinned URL") {
                if let id = model?.activeTab?.id { model?.perform(.resetPinnedTab(id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.resetPinnedTab($0.id)) == true } != true)
            Button(model?.activeTab?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let tab = model?.activeTab { model?.perform(.setFavorite(tab.id, !tab.isFavorite)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.setFavorite($0.id, !$0.isFavorite)) == true } != true)
            Divider()
            Menu("Split View") {
                Menu("Split with Tab") {
                    if let model {
                        ForEach(model.openTabs.filter { model.canPerform(.splitTab($0.id, .leading)) || model.canPerform(.splitTab($0.id, .trailing)) }) { tab in
                            Menu(tab.displayTitle) {
                                Button("Place on Left") { model.perform(.splitTab(tab.id, .leading)) }
                                    .disabled(!model.canPerform(.splitTab(tab.id, .leading)))
                                Button("Place on Right") { model.perform(.splitTab(tab.id, .trailing)) }
                                    .disabled(!model.canPerform(.splitTab(tab.id, .trailing)))
                            }
                        }
                    }
                }
                .disabled(model.map { model in !model.openTabs.contains { model.canPerform(.splitTab($0.id, .leading)) || model.canPerform(.splitTab($0.id, .trailing)) } } ?? true)
                if let model, let group = model.coordinator.activeSplitGroup {
                    Divider()
                    Button("Swap Sides") { model.perform(.swapSplit(group.id)) }
                        .disabled(!model.canPerform(.swapSplit(group.id)))
                    Button("Focus Left Pane") { model.perform(.focusSplitPane(group.panes[0].id)) }
                        .disabled(!model.canPerform(.focusSplitPane(group.panes[0].id)))
                    Button("Focus Right Pane") { model.perform(.focusSplitPane(group.panes[1].id)) }
                        .disabled(!model.canPerform(.focusSplitPane(group.panes[1].id)))
                    Button("Remove Current Pane from Split") {
                        if let pane = group.panes.first(where: { $0.tabID == model.coordinator.focusedTabID }) {
                            model.perform(.removeSplitPane(pane.id))
                        }
                    }
                    .disabled(!model.canPerform(.exitSplit(group.id)))
                    Button("Exit Split View") { model.perform(.exitSplit(group.id)) }
                        .disabled(!model.canPerform(.exitSplit(group.id)))
                }
            }
            .disabled(model.map { model in model.coordinator.activeSplitGroup == nil
                && !model.openTabs.contains { model.canPerform(.splitTab($0.id, .leading)) || model.canPerform(.splitTab($0.id, .trailing)) } } ?? true)
            Divider()
            Button("Close Other Tabs") {
                if let id = model?.activeTab?.id { model?.perform(.closeOtherTabs(id)) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(model?.activeTab.map { model?.canPerform(.closeOtherTabs($0.id)) == true } != true)
            Button("Close Tabs Below") {
                if let id = model?.activeTab?.id { model?.perform(.closeTabsBelow(id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.closeTabsBelow($0.id)) == true } != true)
            Button("Clear Today Tabs") { model?.perform(.clearTodayTabs) }
                .disabled(model?.canPerform(.clearTodayTabs) != true)
        }
        CommandMenu("Space") {
            Button("New Space…") { model?.perform(.newSpace) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model?.canPerform(.newSpace) != true)
            if let model, let space = model.coordinator.activeSpace {
                Group { SpaceActions(model: model, space: space) }
                    .disabled(!model.canManageSpaces)
            }
            Divider()
            Button("Previous Space") { model?.perform(.cycleSpace(-1)) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model?.canPerform(.cycleSpace(-1)) != true)
            Button("Next Space") { model?.perform(.cycleSpace(1)) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model?.canPerform(.cycleSpace(1)) != true)
            Button("Last Space") { model?.perform(.selectSpaceNumber(9)) }
                .keyboardShortcut("9", modifiers: [.command, .option])
                .disabled(model?.canPerform(.selectSpaceNumber(9)) != true)
            if let model {
                ForEach(Array(model.coordinator.spaces.enumerated()), id: \.element.id) { index, space in
                    if index < 8 {
                        Button(space.name) { model.perform(.switchSpace(space.id)) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                            .disabled(!model.canPerform(.switchSpace(space.id)))
                    } else {
                        Button(space.name) { model.perform(.switchSpace(space.id)) }
                            .disabled(!model.canPerform(.switchSpace(space.id)))
                    }
                }
            }
        }
        CommandMenu("Profile") {
            ForEach(application.profiles) { profile in
                Button {
                    if let model { model.perform(.openProfile(profile.id)) }
                    else { application.openProfile(profile.id) }
                } label: {
                    if model?.coordinator.profileID == profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
                .disabled(model.map { !$0.canPerform(.openProfile(profile.id)) } ?? application.profileOperationInProgress)
            }
            Divider()
            Button("Manage Profiles…") {
                application.settingsSection = .profiles
                openSettings()
            }
        }
        #if DEBUG
        // Deterministic layout coverage without relying on synthesized drags
        // being accepted by the macOS window manager. No normal-user menu.
        if model?.isTesting == true {
            CommandMenu("Test Window") {
                Button("Compact Test Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 800, height: 600)) }
                Button("Wide Test Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 1120, height: 760)) }
                // Drive the real AppKit transition with a known binding. The
                // system's fullscreen shortcut varies with macOS/preferences,
                // and its menu bar is hidden while the test is fullscreen.
                Button("Toggle Test Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button("Install Closed Test Pins") {
                    if let model { TestPages.installClosedPins(in: model) }
                }
                .disabled(model?.coordinator.tabStore.tabs.isEmpty != true)
            }
        }
        #endif
    }
}
