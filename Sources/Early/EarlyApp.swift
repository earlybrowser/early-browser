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
        WindowGroup("Early", id: "browser", for: UUID.self) { $windowID in
            BrowserWindowRoot(launchStore: launchStore, appDelegate: appDelegate, windowID: windowID)
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
    private var windows: [(id: UUID, model: BrowserWindowModel)] = []
    private var isTerminating = false
    private var primaryWindowIsOpen = true

    func showPrimaryWindow() { primaryWindowIsOpen = true }

    func windowModel(_ id: UUID) -> BrowserWindowModel? { windows.first { $0.id == id }?.model }

    func install(_ primary: BrowserWindowModel) -> [UUID] {
        model = primary
        attach(primary)
        var restored: [UUID] = []
        for session in primary.restoredWindows {
            let id = UUID()
            let child = primary.siblingWindow(session: session)
            windows.append((id, child))
            attach(child)
            restored.append(id)
        }
        save(primary)
        return restored
    }

    private func attach(_ owner: BrowserWindowModel) {
        owner.onSave = { [weak self] source in self?.save(source) }
        owner.onOpenWindow = { [weak self, weak owner] url, title in
            guard let self, let owner, (try? owner.input.validate(url)) != nil else { return }
            let child = owner.siblingWindow(session: owner.coordinator.session.openingWindow(at: url, title: title))
            let id = UUID()
            self.windows.append((id, child))
            self.attach(child)
            self.save(owner)
            owner.presentWindow?(id)
        }
    }

    private func save(_ source: BrowserWindowModel) {
        guard let model else { return }
        let snapshot = source.coordinator.session
        for target in [model] + windows.map(\.model) where target !== source {
            target.synchronizeSavedItems(from: snapshot)
        }
        let visible = (primaryWindowIsOpen ? [model] : []) + windows.map(\.model)
        var root = (visible.first ?? model).coordinator.session
        root.additionalWindows = visible.dropFirst().map { $0.coordinator.session }
        model.persistence.enqueue(root)
    }

    func closeWindow(_ id: UUID?) {
        guard !isTerminating else { return }
        guard let id else {
            primaryWindowIsOpen = false
            guard let model else { return }
            model.suggestions.cancel()
            // Closing a window closes its live tabs, not another window's copies.
            for tab in model.coordinator.tabStore.tabs where tab.isOpen {
                _ = model.coordinator.closeTab(tab.id)
            }
            model.webViews.discardAll()
            save(model)
            return
        }
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let closed = windows.remove(at: index).model
        closed.onSave = nil
        closed.onOpenWindow = nil
        closed.presentWindow = nil
        closed.suggestions.cancel()
        closed.webViews.discardAll()
        if let model { save(model) }
    }

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
            if canQuit {
                model.webViews.discardAll()
                self.windows.forEach { $0.model.webViews.discardAll() }
            }
            // Quit emits window-close notifications too; those must not delete
            // the window snapshots we just flushed for next launch.
            if !canQuit { self.isTerminating = false }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}

private struct BrowserWindowRoot: View {
    let launchStore: FirstLaunchStore
    let appDelegate: EarlyAppDelegate
    let windowID: UUID?
    @Environment(\.openWindow) private var openWindow
    @State private var model: BrowserWindowModel?

    init(launchStore: FirstLaunchStore, appDelegate: EarlyAppDelegate, windowID: UUID?) {
        self.launchStore = launchStore
        self.appDelegate = appDelegate
        self.windowID = windowID
        _model = State(initialValue: windowID.flatMap { appDelegate.windowModel($0) } ?? (windowID == nil ? appDelegate.model : nil))
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
        .background(WindowRegistration(identifier: windowID.map { "browser.\($0)" } ?? "browser") {
            appDelegate.closeWindow(windowID)
        })
        .task {
            if windowID == nil { appDelegate.showPrimaryWindow() }
            if model == nil {
                if let windowID, let existing = appDelegate.windowModel(windowID) {
                    model = existing
                } else if let existing = appDelegate.model {
                    model = existing
                } else {
                    guard let loaded = await Self.loadModel(launchStore: launchStore) else { return }
                    let restored = appDelegate.install(loaded)
                    model = loaded
                    for id in restored { openWindow(id: "browser", value: id) }
                }
            }
            model?.presentWindow = { id in openWindow(id: "browser", value: id) }
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
            restorationError: restorationError,
            defaults: testSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
    }
}

/// WindowGroup handles native focus/commands. Session restoration is owned by
/// Early's single snapshot writer, not a second AppKit restoration mechanism.
private struct WindowRegistration: NSViewRepresentable {
    let identifier: String
    let onClose: () -> Void
    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.identifierValue = identifier
        view.onClose = onClose
        return view
    }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.identifierValue = identifier
        view.onClose = onClose
        view.register()
    }

    final class RegistrationView: NSView {
        var identifierValue = "browser"
        var onClose: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(identifierValue)
            window.isRestorable = false
            // The chrome's native material composites the wallpaper behind this
            // window. Content/error surfaces still supply their own backgrounds.
            window.isOpaque = false
            window.backgroundColor = .clear
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
        @objc private func windowClosing(_ notification: Notification) { onClose?() }
    }
}
