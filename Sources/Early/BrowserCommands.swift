import AppKit
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
        }
        CommandMenu("Navigate") {
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
                Button("Install Closed Test Pins") {
                    if let model { TestPages.installClosedPins(in: model) }
                }
                .disabled(model?.coordinator.tabStore.tabs.isEmpty != true)
            }
        }
        #endif
    }
}
