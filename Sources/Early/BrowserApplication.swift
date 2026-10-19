// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import Observation
import SwiftUI
import WebKit

/// The application owns the profile catalog and the only session writer.
/// A window and its WebKit manager never change their storage identity.
@MainActor @Observable
final class EarlyAppDelegate: NSObject, NSApplicationDelegate {
    private struct WindowEntry { let id: UUID; let model: BrowserWindowModel }
    private struct Loaded {
        let workspace: BrowserWorkspace
        let repository: SessionRepository
        let input: NavigationInput
        let testing: Bool
        let error: String?
    }

    private(set) var model: BrowserWindowModel?
    private(set) var workspace: BrowserWorkspace?
    private(set) var persistence: SessionAutosaver?
    private(set) var storageURL: URL?
    private(set) var profileOperationInProgress = false
    var profileError: String?
    var settingsSection: BrowserSettingsSection = .appearance
    @ObservationIgnored var presentWindow: ((UUID) -> Void)?
    @ObservationIgnored var presentSettingsWindow: (() -> Void)?
    @ObservationIgnored private var windows: [WindowEntry] = []
    @ObservationIgnored private var loading: Task<Loaded, Never>?
    @ObservationIgnored private var repository: SessionRepository?
    @ObservationIgnored private var preferences: BrowserPreferences?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var input = NavigationInput()
    @ObservationIgnored private var testing = false
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var applyingWorkspace = false
    @ObservationIgnored private var restoringFocus = false
    @ObservationIgnored private var pendingRestoredWindows: Set<UUID> = []
    @ObservationIgnored private var cleaningWebsiteData = false
    private var primaryWindowIsOpen = false

    var profiles: [BrowserProfile] { workspace?.profiles ?? [] }
    var canEditProfiles: Bool { workspace != nil && persistence?.isAvailable == true && !profileOperationInProgress && !isTerminating }
    private var visibleModels: [BrowserWindowModel] { (primaryWindowIsOpen ? model.map { [$0] } ?? [] : []) + windows.map(\.model) }

    func windowModel(_ id: UUID?) -> BrowserWindowModel? {
        guard let id else { return model }
        return windows.first { $0.id == id }?.model
    }

    func bootstrap(launchStore: FirstLaunchStore, preferences: BrowserPreferences, defaults: UserDefaults,
                   storageDirectory: URL? = nil, isTesting: Bool = false) async -> [UUID] {
        guard workspace == nil else { return [] }
        if loading == nil {
            loading = Task {
                var suite: String?
                #if DEBUG
                if let value = ProcessInfo.processInfo.environment["EARLY_TEST_DEFAULTS_SUITE"],
                   value.hasPrefix("local.early.tests."),
                   value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) { suite = value }
                #endif
                let testing = suite != nil || isTesting
                let input = NavigationInput(allowedSchemes: testing ? ["http", "https", "early-test"] : ["http", "https"])
                var directory = storageDirectory ?? URL.applicationSupportDirectory.appending(path: "Early", directoryHint: .isDirectory)
                if storageDirectory == nil, let suite { directory.append(path: "UITests/\(suite)", directoryHint: .isDirectory) }
                let repository = SessionRepository(fileURL: directory.appending(path: "session.sqlite"), input: input)
                do {
                    let saved = try await repository.loadWorkspace() ?? BrowserWorkspace()
                    return Loaded(workspace: saved, repository: repository, input: input, testing: testing, error: nil)
                } catch {
                    return Loaded(workspace: BrowserWorkspace(), repository: repository, input: input, testing: testing,
                        error: "The existing session was left untouched. Browsing is temporary until storage is repaired. \(error.localizedDescription)")
                }
            }
        }
        guard let loaded = await loading?.value, !Task.isCancelled, workspace == nil else { return [] }
        loading = nil
        self.preferences = preferences
        self.defaults = defaults
        self.repository = loaded.repository
        self.storageURL = loaded.repository.fileURL
        self.input = loaded.input
        self.testing = loaded.testing
        let writer = SessionAutosaver(repository: loaded.repository, disabledReason: loaded.error)
        persistence = writer
        var snapshot = loaded.workspace
        if !preferences.restoreSession || snapshot.openProfileIDs.isEmpty {
            snapshot = snapshot.startingWithSavedItemsOnly()
        }
        // A closed profile keeps saved organization, not abandoned Today tabs.
        let active = snapshot.activeProfileID
        let startup = loaded.error == nil ? launchStore.claimStartupContext() : .returningSession
        workspace = snapshot
        let primary = makeModel(session: snapshot.session(for: active)!, startup: startup)
        model = primary
        primaryWindowIsOpen = true
        attach(primary)
        var restored: [UUID] = []
        for session in snapshot.sessions where session.profileID == active || snapshot.openProfileIDs.contains(session.profileID) {
            let sessions = session.profileID == active ? session.additionalWindows : [session] + session.additionalWindows
            for window in sessions { restored.append(addWindow(session: window)) }
        }
        if !snapshot.openProfileIDs.contains(active) { snapshot.openProfileIDs.append(active) }
        workspace = snapshot
        pendingRestoredWindows = Set(restored)
        restoringFocus = !restored.isEmpty
        preferences.onChange = { [weak self] key in
            if key == "browserAppearance" { self?.applyAppearance() }
            if key == "onlineSearchSuggestions" { self?.visibleModels.forEach { $0.refreshSuggestions() } }
            if key == "spaceSwipes" { self?.visibleModels.forEach { $0.cancelSpaceSwipePresentation() } }
        }
        applyAppearance()
        save(primary)
        Task { await retryWebsiteDataCleanup() }
        return restored
    }

    func ensurePrimaryWindow() {
        guard !primaryWindowIsOpen, let workspace else { return }
        let session = workspace.session(for: workspace.defaultProfileID)!.savedItemsOnly
        let primary = makeModel(session: session)
        model = primary
        primaryWindowIsOpen = true
        attach(primary)
        self.workspace?.activeProfileID = workspace.defaultProfileID
        save(primary)
    }

    private func websiteDataStore(for id: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[id] { return store }
        let store = testing ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    private func makeModel(session: BrowserSession, startup: StartupContext = .returningSession) -> BrowserWindowModel {
        BrowserWindowModel(startup: startup, session: session, repository: repository!, input: input, isTesting: testing,
            restorationError: persistence?.error, defaults: defaults, sharedPersistence: persistence,
            websiteDataStore: websiteDataStore(for: session.profileID), preferences: preferences)
    }

    @discardableResult private func addWindow(session: BrowserSession) -> UUID {
        let id = UUID()
        let child = makeModel(session: session)
        windows.append(WindowEntry(id: id, model: child))
        attach(child)
        return id
    }

    private func attach(_ owner: BrowserWindowModel) {
        owner.application = self
        owner.onSave = { [weak self] source in self?.save(source) }
        owner.onOpenWindow = { [weak self, weak owner] url, title in
            guard let self, let owner, !self.isTerminating, (try? owner.input.validate(url)) != nil,
                  self.visibleModels.contains(where: { $0 === owner }) else { return }
            let id = self.addWindow(session: owner.coordinator.session.openingWindow(at: url, title: title))
            self.save(owner)
            self.presentWindow?(id)
        }
        owner.onOpenSettings = { [weak self, weak owner] in
            guard let self, let owner, !self.isTerminating,
                  self.visibleModels.contains(where: { $0 === owner }) else { return }
            self.presentSettingsWindow?()
        }
    }

    private func captureWorkspace(preferred: BrowserWindowModel? = nil) {
        guard var snapshot = workspace else { return }
        for index in snapshot.sessions.indices {
            let id = snapshot.sessions[index].profileID
            var models = visibleModels.filter { $0.coordinator.profileID == id }
            if let preferred, let position = models.firstIndex(where: { $0 === preferred }) {
                models.insert(models.remove(at: position), at: 0)
            }
            guard let first = models.first else { continue }
            var session = first.coordinator.session
            session.additionalWindows = models.dropFirst().map { $0.coordinator.session }
            snapshot.sessions[index] = session
        }
        let open = Set(visibleModels.map { $0.coordinator.profileID })
        snapshot.openProfileIDs = snapshot.profiles.map(\.id).filter { open.contains($0) }
        if !open.contains(snapshot.activeProfileID), let first = snapshot.openProfileIDs.first { snapshot.activeProfileID = first }
        workspace = snapshot
    }

    private func save(_ source: BrowserWindowModel) {
        guard !applyingWorkspace, !isTerminating, visibleModels.contains(where: { $0 === source }) else { return }
        let session = source.coordinator.session
        for target in visibleModels where target !== source && target.coordinator.profileID == source.coordinator.profileID {
            target.synchronizeSavedItems(from: session)
        }
        saveAll()
    }

    func saveAll() {
        guard !applyingWorkspace else { return }
        captureWorkspace()
        if let workspace { persistence?.enqueue(workspace) }
    }

    func focusedWindow(_ id: UUID?) {
        guard !restoringFocus, let owner = windowModel(id), workspace?.activeProfileID != owner.coordinator.profileID else { return }
        workspace?.activeProfileID = owner.coordinator.profileID
        saveAll()
    }

    func windowDidRegister(_ id: UUID?) {
        if let id { pendingRestoredWindows.remove(id) }
        guard restoringFocus, pendingRestoredWindows.isEmpty else { return }
        restoringFocus = false
        // Restoring another profile's background windows must not replace the
        // profile that was frontmost when Early quit.
        DispatchQueue.main.async { [weak self] in
            guard self?.primaryWindowIsOpen == true else { return }
            NSApp.windows.first { $0.identifier?.rawValue == "browser" }?.makeKeyAndOrderFront(nil)
        }
    }

    func openProfile(_ id: UUID) {
        guard !isTerminating, !profileOperationInProgress, let session = workspace?.session(for: id) else { return }
        let identifier: String
        if let model, primaryWindowIsOpen, model.coordinator.profileID == id { identifier = "browser" }
        else if let existing = windows.first(where: { $0.model.coordinator.profileID == id }) { identifier = "browser.\(existing.id)" }
        else {
            let window = addWindow(session: session)
            workspace?.activeProfileID = id
            saveAll()
            presentWindow?(window)
            return
        }
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspace?.activeProfileID = id
        saveAll()
    }

    @discardableResult func createProfile(name: String, color: BrowserSpace.Color) -> UUID? {
        guard canEditProfiles else { return nil }
        let id = workspace?.createProfile(name: name, color: color)
        if id != nil { saveAll() }
        return id
    }

    @discardableResult func editProfile(_ id: UUID, name: String, color: BrowserSpace.Color) -> Bool {
        guard canEditProfiles, workspace?.editProfile(id, name: name, color: color) == true else { return false }
        saveAll()
        return true
    }

    @discardableResult func setDefaultProfile(_ id: UUID) -> Bool {
        guard canEditProfiles, workspace?.setDefaultProfile(id) == true else { return false }
        saveAll()
        return true
    }

    func showSpaceEditor(profileID: UUID, spaceID: UUID?) {
        guard canEditProfiles else { return }
        openProfile(profileID)
        guard let owner = visibleModels.first(where: { $0.coordinator.profileID == profileID }) else { return }
        if let spaceID { owner.requestEditSpace(spaceID, selectOnSave: true) }
        else { owner.requestNewSpace() }
    }

    /// Cross-profile reassignment is an explicit reload, never a transplant of
    /// WebKit views or cookies. Unrelated pages retain their live view identity.
    func moveSpace(_ id: UUID, from owner: BrowserWindowModel, to profileID: UUID,
                   name: String, color: BrowserSpace.Color, icon: SpaceIcon?) -> Bool {
        guard canEditProfiles, !visibleModels.contains(where: { $0.webViews.pages.values.contains(where: \.hasDialog) || $0.sidebarInteractionInProgress }) else { return false }
        captureWorkspace(preferred: owner)
        guard var draft = workspace, let source = draft.sessions.firstIndex(where: { $0.profileID == owner.coordinator.profileID }),
              let space = draft.sessions[source].spaces.firstIndex(where: { $0.id == id }),
              let normalized = BrowserSpace.normalizedName(name) else { return false }
        for index in draft.sessions[source].additionalWindows.indices {
            let local = draft.sessions[source].additionalWindows[index].spaces.firstIndex { $0.id == id }!
            draft.sessions[source].additionalWindows[index].spaces[local].name = normalized
            draft.sessions[source].additionalWindows[index].spaces[local].color = color
            draft.sessions[source].additionalWindows[index].spaces[local].icon = icon
        }
        draft.sessions[source].spaces[space].name = normalized
        draft.sessions[source].spaces[space].color = color
        draft.sessions[source].spaces[space].icon = icon
        guard draft.moveSpace(id, from: owner.coordinator.profileID, to: profileID, using: input) else { return false }
        applyingWorkspace = true
        workspace = draft
        for session in draft.sessions where session.profileID == owner.coordinator.profileID || session.profileID == profileID {
            var models = visibleModels.filter { $0.coordinator.profileID == session.profileID }
            if let index = models.firstIndex(where: { $0 === owner }) { models.insert(models.remove(at: index), at: 0) }
            for (target, snapshot) in zip(models, [session] + session.additionalWindows) { target.applyProfileSnapshot(snapshot) }
        }
        applyingWorkspace = false
        openProfile(profileID)
        saveAll()
        return true
    }

    func deleteProfile(_ id: UUID) async {
        guard canEditProfiles else { return }
        guard id != workspace?.defaultProfileID else {
            profileError = "The Default profile cannot be deleted. You can rename it instead."
            return
        }
        guard !visibleModels.contains(where: { $0.coordinator.profileID == id && $0.webViews.pages.values.contains(where: \.hasDialog) }) else {
            profileError = "Close this profile’s dialogs before deleting it."
            return
        }
        profileOperationInProgress = true
        defer { profileOperationInProgress = false }
        // Record cleanup before removing metadata; a failed save must never
        // delete a website store still referenced by the on-disk catalog.
        var pending = defaults.stringArray(forKey: "pendingProfileCleanup") ?? []
        if !pending.contains(id.uuidString) { pending.append(id.uuidString) }
        defaults.set(pending, forKey: "pendingProfileCleanup")
        let icons = visibleModels.filter { $0.coordinator.profileID == id }.map { $0.webViews.favicons }
        let closing = windows.filter { $0.model.coordinator.profileID == id }.map(\.id)
        for windowID in closing {
            NSApp.windows.first { $0.identifier?.rawValue == "browser.\(windowID)" }?.close()
            closeWindow(windowID)
        }
        if model?.coordinator.profileID == id {
            NSApp.windows.first { $0.identifier?.rawValue == "browser" }?.close()
            closeWindow(nil)
        }
        guard workspace?.deleteProfile(id) == true else { return }
        dataStores.removeValue(forKey: id)
        saveAll()
        guard await persistence?.flush() == true else {
            profileError = "The profile change could not be saved. Its website data was kept. \(persistence?.error ?? "")"
            return
        }
        for store in icons { await store.shutdown() }
        await Task.yield()
        await retryWebsiteDataCleanup()
    }

    func retryWebsiteDataCleanup() async {
        guard persistence?.isAvailable == true, !cleaningWebsiteData else { return }
        cleaningWebsiteData = true
        defer { cleaningWebsiteData = false }
        var attempted = Set<String>()
        // Startup recovery and an interactive deletion can overlap. One worker
        // drains new requests as they arrive; failures wait until next launch.
        while await persistence?.flush() == true {
            let pending = (defaults.stringArray(forKey: "pendingProfileCleanup") ?? []).filter { !attempted.contains($0) }
            guard !pending.isEmpty else { return }
            for value in pending {
                attempted.insert(value)
                guard let id = UUID(uuidString: value), !profiles.contains(where: { $0.id == id }) else { continue }
                do {
                    if !testing {
                        try await WKWebsiteDataStore.remove(forIdentifier: id)
                        try await FaviconStore.removeCache(for: id)
                    }
                    var remaining = defaults.stringArray(forKey: "pendingProfileCleanup") ?? []
                    remaining.removeAll { $0 == value }
                    defaults.set(remaining, forKey: "pendingProfileCleanup")
                } catch {
                    profileError = "The profile was removed, but its website data could not yet be erased. Early will retry on next launch. \(error.localizedDescription)"
                }
            }
        }
    }

    func closeWindow(_ id: UUID?) {
        guard !isTerminating, let closed = windowModel(id) else { return }
        let profileID = closed.coordinator.profileID
        if let id { windows.removeAll { $0.id == id }; windowDidRegister(id) }
        else { primaryWindowIsOpen = false; model = nil }
        closed.onSave = nil
        closed.onOpenWindow = nil
        closed.onOpenSettings = nil
        closed.application = nil
        closed.cancelCommandBarQueries()
        closed.webViews.discardAll()
        if !visibleModels.contains(where: { $0.coordinator.profileID == profileID }),
           let index = workspace?.sessions.firstIndex(where: { $0.profileID == profileID }) {
            workspace?.sessions[index] = closed.coordinator.session.savedItemsOnly
        }
        saveAll()
    }

    func applyAppearance() {
        switch preferences?.appearance ?? .system {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if env["EARLY_TEST_DEFAULTS_SUITE"]?.hasPrefix("local.early.tests.") == true,
               let appearance = env["EARLY_TEST_APPEARANCE"], ["light", "dark"].contains(appearance) {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                return
            }
            #endif
            NSApp.appearance = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let persistence else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        saveAll()
        Task { @MainActor in
            var canQuit = await persistence.flush()
            if !canQuit {
                let alert = NSAlert()
                alert.messageText = "Your session could not be saved"
                alert.informativeText = persistence.error ?? "Session storage is unavailable."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                canQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if canQuit { self.visibleModels.forEach { $0.webViews.discardAll() } }
            else { self.isTerminating = false }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}
