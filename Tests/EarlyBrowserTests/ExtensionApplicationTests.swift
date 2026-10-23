// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import EarlyWeb
import Testing
import WebKit

/// Extensions in the application: each profile runs its own, private windows
/// run only those allowed there, and deleting a profile removes them.
@Suite(.serialized) @MainActor
struct ExtensionApplicationTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyExtensions-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.extensions.\(UUID())"
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

    /// A folder extension with a button and a content script.
    static func extensionFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyAppExtension-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            {"manifest_version": 3, "name": "Early Test", "version": "1.0", "description": "Test",
             "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"]}],
             "action": {"default_title": "Test"}, "permissions": ["storage"], "host_permissions": ["<all_urls>"]}
            """.utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("document.documentElement.dataset.early = 'yes';".utf8).write(to: folder.appending(path: "content.js"))
        return folder
    }

    @Test func eachProfileRunsItsOwnExtensionsAndPrivateWindowsTheirs() async throws {
        guard #available(macOS 15.4, *) else { return }
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let host = try #require(personal.extensionHost as? ExtensionHost)
        #expect(!host.isPrivate && personal.webViews.extensionController === host.controller)
        #expect(personal.extensionWindow is ExtensionWindow)
        #expect(app.extensionHost(for: personal.coordinator.profileID) === host, "One host per profile")

        let workID = try #require(app.createProfile(name: "Work", color: .purple))
        app.openProfile(workID)
        let work = try #require(app.windowModel(fixture.opened.last))
        let workHost = try #require(work.extensionHost as? ExtensionHost)
        #expect(workHost !== host && workHost.catalog !== host.catalog, "Profiles don't share extensions")

        // A private window runs those of the profile it was opened from.
        #expect(work.perform(.newPrivateWindow))
        let privateWorkID = try #require(fixture.opened.last)
        let privateWork = try #require(app.windowModel(privateWorkID))
        let privateHost = try #require(privateWork.extensionHost as? ExtensionHost)
        #expect(privateHost.isPrivate && privateHost.catalog === workHost.catalog)
        #expect(privateWork.webViews.extensionController === privateHost.controller)
        #expect(personal.perform(.newPrivateWindow))
        let privatePersonalID = try #require(fixture.opened.last)
        let privatePersonal = try #require(app.windowModel(privatePersonalID))
        #expect((privatePersonal.extensionHost as? ExtensionHost)?.catalog === host.catalog)
        #expect(app.runningExtensionHosts(of: workID).count == 2)

        // The last private window closing ends the private session's extensions.
        app.closeWindow(privateWorkID)
        #expect(app.runningExtensionHosts(of: workID).count == 2, "Another private window is still open")
        app.closeWindow(privatePersonalID)
        #expect(app.runningExtensionHosts(of: workID).map(\.isPrivate) == [false])
        await fixture.cleanup()
    }

    @Test func choicesApplyInEveryWindowAndPrivateWindowsNeedPermission() async throws {
        guard #available(macOS 15.4, *) else { return }
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let profile = personal.coordinator.profileID
        let host = try #require(personal.extensionHost as? ExtensionHost)
        let folder = try Self.extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let item = try await host.add(files: folder)
        #expect(host.context(item.id) != nil && host.actionExtensions.map(\.id) == [item.id])
        #expect(item.name == "Early Test" && item.version == "1.0" && !item.allowsPrivateWindows)
        let copied = fixture.directory.appending(path: "Extensions/Files/\(profile.uuidString)/\(item.id.uuidString)")
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "manifest.json").path), "Its files are copied into the profile")
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "Extensions/\(profile.uuidString).json").path))

        #expect(personal.perform(.newPrivateWindow))
        let privateWindow = try #require(app.windowModel(fixture.opened.last))
        let privateHost = try #require(privateWindow.extensionHost as? ExtensionHost)
        await privateHost.loadEnabled()
        #expect(privateHost.context(item.id) == nil, "Off in private windows until allowed")
        await app.changeExtension(item.id, in: profile, restart: true) { $0.allowsPrivateWindows = true }
        #expect(privateHost.context(item.id) != nil && host.context(item.id) != nil)

        await app.changeExtension(item.id, in: profile, restart: false) { $0.siteAccess = .whenClicked }
        #expect(host.catalog.installed(item.id)?.siteAccess == .whenClicked)
        #expect(host.context(item.id) != nil, "Website access changes without restarting it")

        await app.changeExtension(item.id, in: profile, restart: true) { $0.isEnabled = false }
        #expect(host.context(item.id) == nil && privateHost.context(item.id) == nil)
        #expect(host.actionExtensions.isEmpty)

        await app.removeExtension(item.id, from: profile)
        #expect(host.catalog.extensions.isEmpty && !FileManager.default.fileExists(atPath: copied.path))
        await fixture.cleanup()
    }

    @Test func extensionsOpenTabsAndSeeTheWindowsTabs() async throws {
        guard #available(macOS 15.4, *) else { return }
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let window = try #require(model.extensionWindow as? ExtensionWindow)
        let page = try #require(URL(string: "early-test://fixture/one"))
        let tab = try #require(model.openExtensionTab(page, active: true))
        #expect(model.coordinator.focusedTabID == tab.id && window.activeTab === tab)
        #expect(model.extensionTabIDs.contains(tab.id))
        let state = try #require(model.extensionTabState(tab.id))
        #expect(state.url == page && !state.isPinned && !state.isMuted)

        let second = try #require(URL(string: "early-test://fixture/two"))
        let background = try #require(model.openExtensionTab(second, active: false))
        #expect(model.coordinator.focusedTabID == tab.id, "A background tab leaves the selection")
        model.extensionActivate(background.id)
        #expect(model.coordinator.focusedTabID == background.id && window.activeTab === background)
        model.extensionClose(background.id)
        #expect(window.tab(background.id) == nil && !model.extensionTabIDs.contains(background.id))

        // Extension pages are allowed addresses, but never history.
        let options = try #require(URL(string: "webkit-extension://\(UUID().uuidString.lowercased())/options.html"))
        #expect(model.openExtensionTab(options, active: true) != nil)
        #expect(!HistoryStore.records(options))
        let script = try #require(URL(string: "javascript:alert(1)"))
        #expect(model.openExtensionTab(script, active: true) == nil)

        // Closing the window tells extensions its tabs went with it.
        app.closeWindow(nil)
        #expect(model.extensionWindow == nil && window.tab(tab.id) == nil)
        await fixture.cleanup()
    }

    @Test(arguments: [false, true])
    func extensionWindowRequestsNeverChangePrivacyMode(isPrivate: Bool) async throws {
        guard #available(macOS 15.4, *) else { return }
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let regular = try #require(app.model)
        let regularHost = try #require(regular.extensionHost as? ExtensionHost)
        let folder = try Self.extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<!doctype html><title>Window requests</title>".utf8).write(to: folder.appending(path: "window.html"))
        let item = try await regularHost.add(files: folder)
        await app.changeExtension(item.id, in: regular.coordinator.profileID, restart: true) { $0.allowsPrivateWindows = true }

        let source: BrowserWindowModel
        if isPrivate {
            #expect(regular.perform(.newPrivateWindow))
            source = try #require(app.windowModel(fixture.opened.last))
        } else { source = regular }
        let host = try #require(source.extensionHost as? ExtensionHost)
        await host.loadEnabled()
        let context = try #require(host.context(item.id))
        let configuration = try #require(context.webViewConfiguration)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.load(URLRequest(url: context.baseURL.appending(path: "window.html")))
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while view.isLoading || view.title != "Window requests" {
            try #require(ContinuousClock.now < deadline, "Extension page loaded")
            try await Task.sleep(for: .milliseconds(50))
        }

        func request(private requested: Bool) async throws -> [String: Any] {
            let result = try await view.callAsyncJavaScript("""
                try {
                    const created = await browser.windows.create({incognito: requested, url: 'early-test://fixture/window'});
                    return {incognito: created.incognito};
                } catch (error) { return {error: error.message}; }
                """, arguments: ["requested": requested], contentWorld: .page)
            return try #require(result as? [String: Any])
        }

        // A regular extension must not open an ordinary window for a private
        // request, nor may a private extension silently change a regular request.
        let count = fixture.opened.count
        let denied = try await request(private: !isPrivate)
        #expect((denied["error"] as? String)?.contains("privacy mode") == true)
        #expect(fixture.opened.count == count, "Rejected requests must not create any window")

        let allowed = try await request(private: isPrivate)
        #expect(allowed["incognito"] as? Bool == isPrivate)
        #expect(fixture.opened.count == count + 1)
        let created = try #require(app.windowModel(fixture.opened.last))
        #expect(created.isPrivate == isPrivate)
        #expect(created.webViews.websiteDataStore === source.webViews.websiteDataStore)
        if isPrivate {
            #expect(!created.webViews.websiteDataStore.isPersistent)
            #expect(created.webViews.websiteDataStore !== regular.webViews.websiteDataStore)
        }
        await fixture.cleanup()
    }

    @Test func deletingAProfileRemovesItsExtensions() async throws {
        guard #available(macOS 15.4, *) else { return }
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let workID = try #require(app.createProfile(name: "Work", color: .green))
        app.openProfile(workID)
        let work = try #require(app.windowModel(fixture.opened.last))
        let host = try #require(work.extensionHost as? ExtensionHost)
        let folder = try Self.extensionFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await host.add(files: folder)
        let catalog = fixture.directory.appending(path: "Extensions/\(workID.uuidString).json")
        let files = fixture.directory.appending(path: "Extensions/Files/\(workID.uuidString)")
        #expect(FileManager.default.fileExists(atPath: catalog.path) && FileManager.default.fileExists(atPath: files.path))

        app.extensionsProfileID = workID
        await app.deleteProfile(workID)
        #expect(!app.profiles.contains { $0.id == workID })
        #expect(!FileManager.default.fileExists(atPath: catalog.path) && !FileManager.default.fileExists(atPath: files.path))
        #expect(app.extensionsProfileID == nil && app.runningExtensionHosts(of: workID).isEmpty)
        #expect(host.contexts.isEmpty)
        await fixture.cleanup()
    }

    @Test func manageExtensionsOpensSettingsForTheWindowsProfile() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        app.showExtensions(profileID: app.extensionsProfileID(of: model))
        #expect(app.settingsSection == .extensions && app.extensionsProfileID == model.coordinator.profileID)
        #expect(fixture.settingsShown == 1)
        #expect(model.perform(.newPrivateWindow))
        let privateWindow = try #require(app.windowModel(fixture.opened.last))
        #expect(app.extensionsProfileID(of: privateWindow) == model.coordinator.profileID,
                "A private window's extensions belong to the profile it came from")
        await fixture.cleanup()
    }

    @Test func addingSaysWhatAnExtensionCanDo() {
        #expect(ExtensionAccess.summary(permissions: ["storage", "tabs"], allSites: true, hosts: [])
                == "It can read and change every website you visit. It may also see your open tabs.")
        #expect(ExtensionAccess.summary(permissions: [], allSites: false, hosts: ["github.com", "example.com"])
                == "It can read and change example.com and github.com.")
        #expect(ExtensionAccess.summary(permissions: ["storage"], allSites: false, hosts: [])
                == "It doesn’t ask to read or change websites.")
        #expect(ExtensionAccess.summary(permissions: ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"], allSites: false, hosts: [])
                == "It may also block or change content on websites.")
        let item = InstalledExtension(source: .files(folderName: "x"), name: "X", version: "1", siteAccess: .whenClicked,
                                      allowedSites: ["example.com"])
        if #available(macOS 15.4, *) {
            #expect(SiteControlsExtensions.accessValue(item, site: "example.com") == "Allowed on this website")
            #expect(SiteControlsExtensions.accessValue(item, site: "github.com") == "Click to use on this page")
            var all = item
            all.siteAccess = .allSites
            #expect(SiteControlsExtensions.accessValue(all, site: nil) == "Allowed on all websites")
        }
    }
}
