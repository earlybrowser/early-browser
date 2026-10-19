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
    let application: EarlyAppDelegate
    @FocusedValue(\.browserWindow) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model?.perform(.presentCommandBar(.newTab)) }
                .keyboardShortcut("t")
                .disabled(model?.canPerform(.presentCommandBar(.newTab)) != true)
            Button("Open Location…") { model?.perform(.presentCommandBar(.navigateCurrentTab)) }
                .keyboardShortcut("l")
                .disabled(model?.canPerform(.presentCommandBar(.navigateCurrentTab)) != true)
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
        }
        CommandMenu("Tab") {
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
            Button(model?.activeTab?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let tab = model?.activeTab { model?.perform(.setFavorite(tab.id, !tab.isFavorite)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.setFavorite($0.id, !$0.isFavorite)) == true } != true)
            Button(model?.activeTab?.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                if let tab = model?.activeTab { model?.perform(.setPinned(tab.id, tab.pinnedURL == nil)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.setPinned($0.id, $0.pinnedURL == nil)) == true } != true)
            Button("Reset to Pinned URL") {
                if let id = model?.activeTab?.id { model?.perform(.resetPinnedTab(id)) }
            }
            .disabled(model?.activeTab.map { model?.canPerform(.resetPinnedTab($0.id)) == true } != true)
            Menu("Move Tab to Space") {
                if let model, let tab = model.activeTab {
                    ForEach(model.coordinator.spaces) { space in
                        Button(space.name) { model.perform(.moveTab(tab.id, toSpace: space.id)) }
                            .disabled(!model.canPerform(.moveTab(tab.id, toSpace: space.id)))
                    }
                }
            }
            .disabled(model?.activeTab == nil || model?.activeTab?.isFavorite == true || model?.canManageSpaces != true)
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
        CommandMenu("Navigate") {
            Button("Copy Current URL") { model?.perform(.copyCurrentURL) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.canPerform(.copyCurrentURL) != true)
            Divider()
            Button("Back") { model?.perform(.back) }.keyboardShortcut("[")
                .disabled(model?.canPerform(.back) != true)
            Button("Forward") { model?.perform(.forward) }.keyboardShortcut("]")
                .disabled(model?.canPerform(.forward) != true)
            Button("Reload") { model?.perform(.reload) }.keyboardShortcut("r")
                .disabled(model?.canPerform(.reload) != true)
            Button("Stop Loading") { model?.perform(.stop) }.keyboardShortcut(".")
                .disabled(model?.canPerform(.stop) != true)
            Divider()
            Button("Reopen Closed Tab") { model?.perform(.reopenLastTab) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model?.canPerform(.reopenLastTab) != true)
            Button("Next Tab") { model?.perform(.cycleTab(1)) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model?.canPerform(.cycleTab(1)) != true)
            Button("Previous Tab") { model?.perform(.cycleTab(-1)) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model?.canPerform(.cycleTab(-1)) != true)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") { model?.perform(.selectTabNumber(number)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))))
                    .disabled(model?.canPerform(.selectTabNumber(number)) != true)
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
