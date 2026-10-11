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
        #if DEBUG
        // App-local appearance coverage, after NSApplication exists. Never
        // change system preferences or the appearance of a normal browser run.
        let environment = ProcessInfo.processInfo.environment
        if environment["EARLY_TEST_DEFAULTS_SUITE"]?.hasPrefix("local.early.tests.") == true,
           let appearance = environment["EARLY_TEST_APPEARANCE"],
           ["light", "dark"].contains(appearance) {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        #endif
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

    init(launchStore: FirstLaunchStore, appDelegate: EarlyAppDelegate) {
        self.launchStore = launchStore
        self.appDelegate = appDelegate
        _model = State(initialValue: appDelegate.model)
    }

    var body: some View {
        Group {
            if let model {
                BrowserWindowView(model: model)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay(alignment: .topLeading) {
                        // Present native, muted controls while the session loads.
                        // The browser's host takes ownership without restoring an
                        // intermediate colored titlebar when this shell disappears.
                        WindowControls()
                            .frame(width: 60, height: 32)
                            .padding(.leading, 12)
                            .padding(.top, 10)
                    }
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            guard model == nil else { return }
            if let existing = appDelegate.model { model = existing; return }
            guard let loaded = await Self.loadModel(launchStore: launchStore) else { return }
            appDelegate.model = loaded
            model = loaded
        }
    }

    private static func loadModel(launchStore: FirstLaunchStore) async -> BrowserWindowModel? {
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
        do {
            if let saved = try await repository.load() {
                session = saved
            }
        } catch {
            restorationError = "The existing session was left untouched. Browsing is temporary until storage is repaired. \(error.localizedDescription)"
        }
        // A discarded SwiftUI task must not claim first launch, create web views,
        // or start an autosaver after its window has disappeared.
        guard !Task.isCancelled else { return nil }
        let startup = launchStore.claimStartupContext()
        return BrowserWindowModel(startup: restorationError == nil ? startup : .returningSession,
            session: session, repository: repository, input: input, isTesting: testSuite != nil,
            restorationError: restorationError)
    }
}
