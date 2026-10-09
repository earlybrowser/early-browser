import AppKit
import EarlyCore
import SwiftUI

@main
struct EarlyApp: App {
    @NSApplicationDelegateAdaptor(EarlyAppDelegate.self) private var appDelegate
    private let launchStore: FirstLaunchStore

    init() {
        var defaults = UserDefaults.standard
        #if DEBUG
        // An isolated preference domain lets UI tests exercise first launch
        // and relaunch without modifying the user's normal app preferences.
        if let suite = ProcessInfo.processInfo.environment["EARLY_TEST_DEFAULTS_SUITE"],
           suite.hasPrefix("local.early.tests."),
           let testDefaults = UserDefaults(suiteName: suite) {
            defaults = testDefaults
        }
        #endif
        launchStore = FirstLaunchStore(defaults: defaults)
    }

    var body: some Scene {
        Window("Early", id: "browser") {
            BrowserWindowRoot(launchStore: launchStore)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
        .commands { BrowserCommands() }
    }
}

@MainActor
final class EarlyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Establish normal foreground app behavior when launched by developer tools.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct BrowserWindowRoot: View {
    let launchStore: FirstLaunchStore
    @State private var model: BrowserWindowModel?

    var body: some View {
        Group {
            if let model {
                BrowserWindowView(model: model)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .onAppear {
                        // Claim once, when a real window appears, not during
                        // transient SwiftUI view construction.
                        guard model == nil else { return }
                        model = BrowserWindowModel(startup: launchStore.claimStartupContext())
                    }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
