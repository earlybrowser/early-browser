// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

@main
struct EarlyApp: App {
    @NSApplicationDelegateAdaptor(EarlyAppDelegate.self) private var appDelegate
    private let launchStore: FirstLaunchStore
    private let preferences: BrowserPreferences
    private let defaults: UserDefaults

    init() {
        var defaults = UserDefaults.standard
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["EARLY_TEST_DEFAULTS_SUITE"],
           suite.hasPrefix("local.early.tests."), let isolated = UserDefaults(suiteName: suite) { defaults = isolated }
        #endif
        self.defaults = defaults
        launchStore = FirstLaunchStore(defaults: defaults)
        preferences = BrowserPreferences(defaults: defaults)
    }

    var body: some Scene {
        WindowGroup("Early", id: "browser", for: UUID.self) { $windowID in
            BrowserWindowRoot(launchStore: launchStore, preferences: preferences, defaults: defaults,
                              appDelegate: appDelegate, windowID: windowID)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { BrowserCommands(application: appDelegate) }

        Settings {
            BrowserSettingsView(application: appDelegate, preferences: preferences)
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentMinSize)
    }
}

private struct BrowserWindowRoot: View {
    let launchStore: FirstLaunchStore
    let preferences: BrowserPreferences
    let defaults: UserDefaults
    let appDelegate: EarlyAppDelegate
    let windowID: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let model = appDelegate.windowModel(windowID) {
                BrowserWindowView(model: model)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay(alignment: .topLeading) {
                        WindowControls().frame(width: 60, height: 32).padding(.leading, 12).padding(.top, 10)
                    }
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(WindowRegistration(identifier: windowID.map { "browser.\($0)" } ?? "browser",
            onClose: { appDelegate.closeWindow(windowID) }, onFocus: { appDelegate.focusedWindow(windowID) },
            onRegister: { appDelegate.windowDidRegister(windowID) }))
        .task {
            appDelegate.presentWindow = { id in openWindow(id: "browser", value: id) }
            let restored = await appDelegate.bootstrap(launchStore: launchStore, preferences: preferences, defaults: defaults)
            guard !Task.isCancelled else { return }
            if windowID == nil { appDelegate.ensurePrimaryWindow() }
            for id in restored { openWindow(id: "browser", value: id) }
        }
    }
}

/// Native windows have stable identifiers; Early alone restores snapshots.
private struct WindowRegistration: NSViewRepresentable {
    let identifier: String
    let onClose: () -> Void
    let onFocus: () -> Void
    let onRegister: () -> Void

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.identifierValue = identifier
        view.onClose = onClose
        view.onFocus = onFocus
        view.onRegister = onRegister
        return view
    }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.identifierValue = identifier
        view.onClose = onClose
        view.onFocus = onFocus
        view.onRegister = onRegister
        view.register()
    }

    final class RegistrationView: NSView {
        var identifierValue = "browser"
        var onClose: (() -> Void)?
        var onFocus: (() -> Void)?
        var onRegister: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(identifierValue)
            window.setAccessibilityIdentifier(identifierValue)
            window.isRestorable = false
            window.isOpaque = false
            window.backgroundColor = .clear
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocused(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            DispatchQueue.main.async { [weak self] in self?.onRegister?() }
        }
        @objc private func windowClosing(_ notification: Notification) { onClose?() }
        @objc private func windowFocused(_ notification: Notification) { onFocus?() }
    }
}
