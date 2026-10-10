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
            BrowserWindowRoot(launchStore: launchStore, appDelegate: appDelegate)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { BrowserCommands() }
    }
}

@MainActor
final class EarlyAppDelegate: NSObject, NSApplicationDelegate {
    var model: BrowserWindowModel?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Establish normal foreground app behavior when launched by developer tools.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        model.save()
        Task { @MainActor in
            var canQuit = await model.persistence.flush()
            if !canQuit {
                let alert = NSAlert()
                alert.messageText = "Your session could not be saved"
                alert.informativeText = model.persistence.error ?? "Session storage is unavailable."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                canQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if canQuit { model.webViews.discardAll() }
            self.isTerminating = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}

private struct BrowserWindowRoot: View {
    let launchStore: FirstLaunchStore
    let appDelegate: EarlyAppDelegate
    @State private var model: BrowserWindowModel?

    var body: some View {
        Group {
            if let model {
                BrowserWindowView(model: model)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            guard model == nil else { return }
            if let existing = appDelegate.model { model = existing; return }
            var testSuite: String?
            #if DEBUG
            if let value = ProcessInfo.processInfo.environment["EARLY_TEST_DEFAULTS_SUITE"],
               value.hasPrefix("local.early.tests."),
               value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) {
                testSuite = value
            }
            #endif
            let input = NavigationInput(allowedSchemes: testSuite == nil ? ["http", "https"] : ["http", "https", "early-test"])
            var directory = URL.applicationSupportDirectory.appending(path: "Early", directoryHint: .isDirectory)
            if let testSuite { directory.append(path: "UITests/\(testSuite)", directoryHint: .isDirectory) }
            let repository = SessionRepository(fileURL: directory.appending(path: "session.sqlite"), input: input)
            var session = BrowserSession()
            var restorationError: String?
            do { if let saved = try await repository.load() { session = saved } }
            catch {
                restorationError = "The existing session was left untouched. Browsing is temporary until storage is repaired. \(error.localizedDescription)"
            }
            guard !Task.isCancelled else { return }
            let startup = launchStore.claimStartupContext()
            let restored = BrowserWindowModel(startup: restorationError == nil ? startup : .returningSession,
                session: session, repository: repository, input: input, isTesting: testSuite != nil,
                restorationError: restorationError)
            appDelegate.model = restored
            model = restored
        }
    }
}
