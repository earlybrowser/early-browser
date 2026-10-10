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
    }
}
