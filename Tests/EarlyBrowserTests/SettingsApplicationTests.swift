// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import EarlyWeb
import SwiftUI
import Testing
import WebKit

/// Settings reaching the windows: the search engine, empty windows, pins, the
/// tab switcher, shortcuts and Privacy. Nothing here sends a search anywhere.
@Suite(.serialized) @MainActor
struct SettingsApplicationTests {
    private let one = URL(string: "early-test://fixture/one")!
    private let two = URL(string: "early-test://fixture/two")!

    @MainActor private final class Fixture {
        let suite = "local.early.tests.settingsapp.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
        }

        func model(_ session: BrowserSession = BrowserSession(), startup: StartupContext = .returningSession) -> BrowserWindowModel {
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlySettings-\(UUID()).sqlite"), input: input)
            return BrowserWindowModel(startup: startup, session: session, repository: repository, input: input, isTesting: true,
                                      restorationError: nil, defaults: defaults, preferences: preferences)
        }

        func cleanup(_ models: BrowserWindowModel...) {
            for model in models { model.cancelCommandBarQueries(); model.webViews.discardAll() }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func theChosenEngineSearchesAndNamesItself() {
        let fixture = Fixture()
        let model = fixture.model()
        defer { fixture.cleanup(model) }
        #expect(model.webViews.searchEngineName() == "Google" && model.onlineSuggestionsEnabled)
        fixture.preferences.searchEngine = .duckDuckGo
        #expect(model.webViews.searchEngineName() == "DuckDuckGo")
        #expect(model.pasteKind(for: "swift ui") == .search && model.pasteKind(for: "example.com") == .address)
        #expect(model.onlineSuggestionsEnabled)
        // Kagi offers no suggestions: none are fetched from anyone.
        fixture.preferences.searchEngine = .kagi
        #expect(!model.onlineSuggestionsEnabled)
    }

    @Test func emptyWindowsShowTheCommandBarAsChosenAndTheFirstLaunchAlways() {
        let fixture = Fixture()
        let usual = fixture.model()
        #expect(usual.coordinator.commandBar?.intent == .newTab)
        fixture.preferences.showsCommandBarInEmptyWindows = false
        let quiet = fixture.model()
        #expect(quiet.coordinator.commandBar == nil && quiet.coordinator.activeTabID == nil)
        let first = fixture.model(startup: .firstLaunch)
        #expect(first.coordinator.commandBar?.intent == .newTab, "The first usable state is always the command bar")
        fixture.cleanup(usual, quiet, first)
    }

    @Test func closingAPinKeepsItsPageWhenChosen() throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { fixture.cleanup(model) }
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery(one.absoluteString)
        #expect(model.perform(.submit()))
        let id = try #require(model.coordinator.activeTabID)
        #expect(model.perform(.setPinned(id, true)))
        _ = model.coordinator.updateMetadata(id, url: two, title: "Two")

        fixture.preferences.pinsResetWhenClosed = false
        model.closeTab(id)
        #expect(model.coordinator.tabStore.tab(id: id).map { !$0.isOpen && $0.currentURL == two } == true)
        _ = model.coordinator.openTab(id)
        fixture.preferences.pinsResetWhenClosed = true
        model.closeTab(id)
        #expect(model.coordinator.tabStore.tab(id: id)?.currentURL == one, "Back to its saved page")
    }

    @Test func controlTabSwitchesInSidebarOrderWithoutTheSwitcher() throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { fixture.cleanup(model) }
        for url in [one, two] {
            #expect(model.perform(.presentCommandBar(.newTab)))
            model.updateQuery(url.absoluteString)
            #expect(model.perform(.submit()))
        }
        let last = try #require(model.coordinator.activeTabID)
        fixture.preferences.controlTabShowsSwitcher = false
        #expect(model.canControlTab(1) && model.controlTab(1))
        #expect(model.tabSwitcher == nil && model.coordinator.activeTabID != last, "Straight to the next tab")

        fixture.preferences.controlTabShowsSwitcher = true
        #expect(model.controlTab(1) && model.tabSwitcher != nil)
        model.cancelTabSwitcher(restoreFocus: false)
    }

    @Test func shortcutsReachMenusAndRecordedKeys() throws {
        let fixture = Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let preferences = fixture.preferences
        #expect(preferences.keyboardShortcut(.newTab) == KeyboardShortcut("t"))
        #expect(preferences.keyboardShortcut(.previousSpace) == KeyboardShortcut(.leftArrow, modifiers: [.command, .option]))
        #expect(preferences.shortcutHint(.newTab) == " (⌘T)" && preferences.shortcutHint(.duplicateTab) == "")
        preferences.shortcuts.assign(BrowserShortcut("f5", []), to: .duplicateTab)
        #expect(preferences.keyboardShortcut(.duplicateTab)?.modifiers == [])
        preferences.shortcuts.remove(.newTab)
        #expect(preferences.keyboardShortcut(.newTab) == nil && preferences.shortcutHint(.newTab) == "")

        func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> BrowserShortcut? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                .flatMap(BrowserShortcut.init(event:))
        }
        #expect(press("k", keyCode: 40, [.command, .shift]) == BrowserShortcut("k", [.command, .shift]))
        #expect(press("", keyCode: 123, [.command, .option]) == BrowserShortcut("leftArrow", [.command, .option]))
        #expect(press("", keyCode: 96, []) == BrowserShortcut("f5", []))
        #expect(press("\u{1b}", keyCode: 53, []) == nil, "Escape stops recording")
    }

    @Test func privacyListsPermissionsAndClearsAProfileWithoutAWindow() async throws {
        let rows = PrivacySettingsSection.permissionRows([
            "https://zoom.example": [.camera: .allow, .microphone: .block],
            "https://a.example:8443": [.location: .allow],
        ])
        #expect(rows.map(\.origin) == ["https://a.example:8443", "https://zoom.example"])
        #expect(rows[1].choices.map(\.0) == [.camera, .microphone])
        #expect(PrivacySettingsSection.host(of: "https://a.example:8443") == "a.example")
        #expect(PrivacySettingsSection.kinds([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage]) == "Cookies, stored data")
        #expect(PrivacySettingsSection.kinds([]) == "Website data")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPrivacy-\(UUID())", isDirectory: true)
        let fixture = Fixture()
        let app = EarlyAppDelegate()
        app.presentWindow = { _ in }
        _ = await app.bootstrap(launchStore: FirstLaunchStore(defaults: fixture.defaults), preferences: fixture.preferences,
                                defaults: fixture.defaults, storageDirectory: directory, isTesting: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try #require(app.workspace?.activeProfileID)
        let history = try #require(app.history(for: profile))
        try await history.record(one, title: "One", at: Date())
        app.closeWindow(nil)
        #expect(await app.websiteData(for: profile).isEmpty)
        await app.clearHistory(.all, profile: profile)
        #expect(try await history.visits().isEmpty, "Cleared with no window open")
        _ = await app.persistence?.flush()
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
    }
}
