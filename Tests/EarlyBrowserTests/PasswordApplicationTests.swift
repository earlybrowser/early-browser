// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import EarlyWeb
import Testing

/// Saved passwords in the application: per profile, filled but never saved
/// in private windows, and shown in Settings only behind the lock. Testing
/// keeps passwords in memory; the Keychain is never used.
@Suite(.serialized) @MainActor
struct PasswordApplicationTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPasswords-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.passwords.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        var opened: [UUID] = []
        var settingsShown = 0

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            application.presentWindow = { [weak self] in self?.opened.append($0) }
            application.presentSettingsWindow = { [weak self] in self?.settingsShown += 1 }
        }

        func start() async {
            _ = await application.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
        }

        func cleanup() async {
            _ = await application.persistence?.flush()
            for id in opened { application.closeWindow(id) }
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func eachProfileHasItsOwnPasswordsAndPrivateWindowsFillFromTheirs() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let personalVault = try #require(personal.passwords)
        #expect(personal.webViews.passwords === personalVault && personal.webViews.savesPasswords)
        #expect(personal.passwordsProfileID == personal.coordinator.profileID)
        #expect(app.passwords(for: personal.coordinator.profileID) === personalVault, "One vault per profile")

        let workID = try #require(app.createProfile(name: "Work", color: .purple))
        app.openProfile(workID)
        let work = try #require(app.windowModel(fixture.opened.last))
        let workVault = try #require(work.passwords)
        #expect(workVault !== personalVault && work.passwordsProfileID == workID)
        personalVault.save(origin: "https://example.com", username: "personal", password: "one")
        #expect(workVault.logins.isEmpty, "Profiles don't share passwords")

        // A private window fills from the profile it was opened from, and never saves.
        #expect(work.perform(.newPrivateWindow))
        let privateWork = try #require(app.windowModel(fixture.opened.last))
        #expect(privateWork.isPrivate && privateWork.passwords === workVault && privateWork.passwordsProfileID == workID)
        #expect(privateWork.webViews.passwords === workVault && !privateWork.webViews.savesPasswords)
        #expect(app.passwords(for: privateWork.coordinator.profileID) == nil, "The private session has none of its own")
        #expect(personal.perform(.newPrivateWindow))
        let privatePersonal = try #require(app.windowModel(fixture.opened.last))
        #expect(privatePersonal.passwords === personalVault, "Each private window keeps the profile it came from")
        await fixture.cleanup()
    }

    @Test func showPasswordsOpensSettingsForTheWindowsProfile() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        #expect(model.canPerform(.showPasswords))
        #expect(model.commandSearchCandidates().contains { $0.id == "action.showPasswords" })
        #expect(model.perform(.showPasswords))
        #expect(app.settingsSection == .passwords && app.passwordsProfileID == model.coordinator.profileID)
        #expect(fixture.settingsShown == 1 && app.passwordSearch.isEmpty)
        model.showPasswords(search: "github.com")
        #expect(app.passwordSearch == "github.com" && fixture.settingsShown == 2)

        // Without passwords (a bare window) there is nothing to show.
        let bare = BrowserWindowModel(startup: .returningSession, session: BrowserSession(), repository: SessionRepository(
            fileURL: fixture.directory.appending(path: "bare.sqlite"), input: NavigationInput()), input: NavigationInput(),
            isTesting: true, restorationError: nil, defaults: fixture.defaults)
        #expect(!bare.canPerform(.showPasswords) && bare.webViews.passwords == nil)
        bare.webViews.discardAll()
        await fixture.cleanup()
    }

    @Test func theLockAsksBeforeShowingAndLocksInTheBackground() async {
        let lock = PasswordsLock()
        var reasons: [String] = []
        var allow = false
        lock.authenticate = { reason in
            reasons.append(reason)
            return allow
        }
        #expect(await lock.unlock() == false && !lock.isUnlocked)
        allow = true
        #expect(await lock.unlock() && lock.isUnlocked)
        #expect(await lock.unlock() && reasons.count == 2, "Already unlocked: no second prompt")
        #expect(await lock.confirm("export your saved passwords"))
        #expect(reasons == ["show your saved passwords", "show your saved passwords", "export your saved passwords"],
                "Exporting always asks again")
        // A Touch ID or Keychain prompt makes Early inactive for a moment.
        await lock.prompting {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        }
        #expect(lock.isUnlocked, "Early's own prompts don't lock Passwords")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!lock.isUnlocked, "Switching away from Early locks Passwords")
        allow = false
        #expect(await lock.unlock() == false && !lock.isUnlocked)
    }

    @Test func importingReportsWhatHappenedAndCopiedPasswordsAreConcealed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EarlyPasswordImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = PasswordVault(fileURL: nil, key: nil)
        vault.save(origin: "https://github.com", username: "ada", password: "kept")
        let file = directory.appending(path: "Chrome Passwords.csv")
        try Data("""
            name,url,username,password,note
            GitHub,https://github.com/,ada,different,
            Example,https://example.com/,grace,pw,
            App,android://x@com.example/,me,pw,
            """.utf8).write(to: file)
        let notice = PasswordsSettingsSection.importFile(file, into: vault)
        #expect(notice.title == "Passwords imported" && notice.importedFile == file)
        #expect(notice.message.hasPrefix("1 password was imported. 1 differs from a saved password; your saved one was kept. 1 without a website or password was skipped."),
                "\(notice.message)")
        #expect(vault.logins.count == 2 && vault.login(origin: "https://github.com", username: "ada")?.password == "kept")

        let other = directory.appending(path: "contacts.csv")
        try Data("name,phone\nAda,1\n".utf8).write(to: other)
        #expect(PasswordsSettingsSection.importFile(other, into: vault).title == "No passwords found")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.early.tests.passwords.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        PasswordsSettingsSection.copy("secret", concealed: true, pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == "secret")
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        PasswordsSettingsSection.copy("ada", concealed: false, pasteboard: pasteboard)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == false)
    }

    @Test func siteControlsDontOpenPasswordsJustToCountThem() {
        #expect(SiteControlsPanel.passwordsValue(nil) == "Saved passwords")
        #expect(SiteControlsPanel.passwordsValue(0) == "None saved for this site")
        #expect(SiteControlsPanel.passwordsValue(1) == "1 saved for this site")
        #expect(SiteControlsPanel.passwordsValue(3) == "3 saved for this site")
        #expect(PasswordEditorSheet.origin("github.com/login") == "https://github.com")
        #expect(PasswordEditorSheet.origin("http://intranet:8080") == "http://intranet:8080")
        #expect(PasswordEditorSheet.origin("not a site") == nil && PasswordEditorSheet.origin("") == nil)
    }
}
