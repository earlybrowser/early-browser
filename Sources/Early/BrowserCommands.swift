// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
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
    @FocusedValue(\.browserWindow) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model?.presentCommandBar(.newTab) }
                .keyboardShortcut("t")
                .disabled(model == nil)
            Button("Open Location…") { model?.presentCommandBar(.navigateCurrentTab) }
                .keyboardShortcut("l")
                .disabled(model == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(model == nil ? "Close Window" : "Close Tab") {
                if let model {
                    model.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Tab") {
            Button("Open Tab in New Window") {
                if let tab = model?.activeTab { model?.openTabInNewWindow(tab.id) }
            }
            .disabled(model?.activeTab == nil)
            Button("Rename Tab…") {
                if let id = model?.activeTab?.id { model?.requestRename(id) }
            }
            .disabled(model?.activeTab == nil)
            Button(model?.activeTab?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let tab = model?.activeTab { model?.setFavorite(tab.id, favorite: !tab.isFavorite) }
            }
            .disabled(model?.activeTab == nil)
            Button(model?.activeTab?.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                if let tab = model?.activeTab { model?.setPinned(tab.id, pinned: tab.pinnedURL == nil) }
            }
            .disabled(model?.activeTab == nil || model?.activeTab?.isFavorite == true)
            Button("Reset to Pinned URL") {
                if let id = model?.activeTab?.id { model?.resetPinnedTab(id) }
            }
            .disabled(model?.activeTab?.pinnedURL == nil)
            Menu("Move Tab to Space") {
                if let model, let tab = model.activeTab {
                    ForEach(model.coordinator.spaces) { space in
                        Button(space.name) { _ = model.moveTab(tab.id, toSpace: space.id) }
                            .disabled(space.id == tab.spaceID)
                    }
                }
            }
            .disabled(model?.activeTab == nil || model?.activeTab?.isFavorite == true || model?.canManageSpaces != true)
        }
        CommandMenu("Space") {
            Button("New Space…") { model?.requestNewSpace() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model?.canManageSpaces != true)
            if let model, let space = model.coordinator.activeSpace {
                Group { SpaceActions(model: model, space: space) }
                    .disabled(!model.canManageSpaces)
            }
            Divider()
            Button("Previous Space") { model?.cycleSpace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model?.canManageSpaces != true || (model?.activeSpaceIndex ?? 0) == 0)
            Button("Next Space") { model?.cycleSpace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model?.canManageSpaces != true || (model?.activeSpaceIndex ?? 0) + 1 >= (model?.coordinator.spaces.count ?? 0))
            Button("Last Space") { model?.selectSpace(number: 9) }
                .keyboardShortcut("9", modifiers: [.command, .option])
                .disabled(model?.canManageSpaces != true)
            if let model {
                ForEach(Array(model.coordinator.spaces.enumerated()), id: \.element.id) { index, space in
                    if index < 8 {
                        Button(space.name) { _ = model.switchSpace(to: space.id) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                            .disabled(!model.canManageSpaces)
                    } else {
                        Button(space.name) { _ = model.switchSpace(to: space.id) }
                            .disabled(!model.canManageSpaces)
                    }
                }
            }
        }
        CommandMenu("Navigate") {
            Button("Copy Current URL") { model?.copyCurrentURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.currentPageURL == nil)
            Divider()
            Button("Back") { model?.back() }.keyboardShortcut("[")
                .disabled(model?.activePage?.canGoBack != true)
            Button("Forward") { model?.forward() }.keyboardShortcut("]")
                .disabled(model?.activePage?.canGoForward != true)
            Button("Reload") { model?.reload() }.keyboardShortcut("r")
                .disabled(model?.activePage == nil)
            Button("Stop Loading") { model?.stop() }.keyboardShortcut(".")
                .disabled(model?.activePage?.isLoading != true)
            Divider()
            Button("Reopen Closed Tab") { model?.reopenLastTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model?.coordinator.recentlyClosed.isEmpty != false)
            Button("Next Tab") { model?.cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model?.openTabs.isEmpty != false)
            Button("Previous Tab") { model?.cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model?.openTabs.isEmpty != false)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") { model?.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))))
                    .disabled(model?.openTabs.isEmpty != false)
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
