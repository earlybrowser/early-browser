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
        let preferences = BrowserPreferences(defaults: defaults)
        self.preferences = preferences
        EarlyAppDelegate.applyAppearance(preferences.appearance)
    }

    var body: some Scene {
        WindowGroup("Early", id: "browser", for: UUID.self) { $windowID in
            BrowserWindowRoot(launchStore: launchStore, preferences: preferences, defaults: defaults,
                              appDelegate: appDelegate, windowID: windowID)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { BrowserCommands(application: appDelegate, preferences: preferences, front: appDelegate.frontWindowState) }

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
    @State private var hasPresentedContent = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let model = appDelegate.windowModel(windowID) {
                BrowserWindowView(model: model)
                    // Names the window in the Window menu and for VoiceOver.
                    .navigationTitle(model.isPrivate ? "Early — Private" : "Early")
            } else {
                BrowserWindowLoadingView(preferences: preferences)
            }
        }
        .transaction { transaction in
            if !hasPresentedContent {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // Links from other apps come to an open window rather than a new one.
        // A window SwiftUI opens for one, with none open, is the browser window.
        .onOpenURL { url in
            if windowID == nil { appDelegate.ensurePrimaryWindow() }
            appDelegate.openExternalLinks([url])
        }
        .background(WindowRegistration(identifier: windowID.map { "browser.\($0)" } ?? "browser",
            contentReady: appDelegate.windowModel(windowID) != nil,
            onPresent: { hasPresentedContent = true },
            onClose: { appDelegate.closeWindow(windowID) }, onFocus: { appDelegate.focusedWindow(windowID) },
            onRegister: { window in appDelegate.windowDidRegister(windowID, window: window) }))
        .task {
            appDelegate.presentWindow = { id in openWindow(id: "browser", value: id) }
            appDelegate.presentSettingsWindow = { openSettings() }
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
    let contentReady: Bool
    let onPresent: () -> Void
    let onClose: () -> Void
    let onFocus: () -> Void
    let onRegister: (NSWindow) -> Void

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.identifierValue = identifier
        view.contentReady = contentReady
        view.onPresent = onPresent
        view.onClose = onClose
        view.onFocus = onFocus
        view.onRegister = onRegister
        return view
    }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.identifierValue = identifier
        view.contentReady = contentReady
        view.onPresent = onPresent
        view.onClose = onClose
        view.onFocus = onFocus
        view.onRegister = onRegister
        view.register()
    }

    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) {
        view.startup.detach()
    }

    final class RegistrationView: NSView {
        var identifierValue = "browser"
        var contentReady = false
        var onPresent: (() -> Void)?
        let startup = BrowserWindowStartupPresentation()
        var onClose: (() -> Void)?
        var onFocus: (() -> Void)?
        var onRegister: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            guard let window else { startup.detach(); return }
            window.identifier = NSUserInterfaceItemIdentifier(identifierValue)
            window.setAccessibilityIdentifier(identifierValue)
            window.isRestorable = false
            window.isOpaque = false
            window.backgroundColor = .clear
            startup.update(window: window, contentReady: contentReady, onPresent: { [weak self] in self?.onPresent?() })
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowFocused(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.onRegister?(window) }
            }
        }
        @objc private func windowClosing(_ notification: Notification) { onClose?() }
        @objc private func windowFocused(_ notification: Notification) { onFocus?() }
    }
}
