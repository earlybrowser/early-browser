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
    }
}
