// SPDX-License-Identifier: MPL-2.0

@testable import EarlyCore
import Foundation
import Testing

/// Settings that change what Early does: the search engine, shortcuts,
/// startup and pins, the tab switcher, and update preferences.
@Suite(.serialized) @MainActor
struct SettingsPreferencesTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "local.early.tests.settings.\(UUID())"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func everyEngineSearchesItselfAndGoogleStaysTheDefault() throws {
        let input = NavigationInput()
        #expect(try input.resolve("swift ui").absoluteString == "https://www.google.com/search?q=swift%20ui")
        let expected: [SearchEngine: String] = [
            .google: "https://www.google.com/search?q=caf%C3%A9%20%26%20tea",
            .duckDuckGo: "https://duckduckgo.com/?q=caf%C3%A9%20%26%20tea",
            .bing: "https://www.bing.com/search?q=caf%C3%A9%20%26%20tea",
            .ecosia: "https://www.ecosia.org/search?q=caf%C3%A9%20%26%20tea",
            .brave: "https://search.brave.com/search?q=caf%C3%A9%20%26%20tea",
            .kagi: "https://kagi.com/search?q=caf%C3%A9%20%26%20tea",
        ]
        for engine in SearchEngine.allCases {
            #expect(try input.searchURL(for: "  café & tea ", engine: engine).absoluteString == expected[engine])
        }
        // An address is still an address, whichever engine is chosen.
        #expect(try input.resolve("example.com/path", engine: .duckDuckGo).absoluteString == "https://example.com/path")
        #expect(try input.resolve("what is swift", engine: .bing).host == "www.bing.com")

        // Suggestions come from the chosen engine itself, or not at all.
        #expect(SearchEngine.google.suggestionURL(for: "swift")?.host == "www.google.com")
        #expect(SearchEngine.duckDuckGo.suggestionURL(for: "swift")?.absoluteString == "https://duckduckgo.com/ac/?q=swift&type=list")
        #expect(SearchEngine.bing.suggestionURL(for: "swift")?.host == "api.bing.com")
        #expect(SearchEngine.ecosia.suggestionURL(for: "swift")?.host == "ac.ecosia.org")
        #expect(SearchEngine.brave.suggestionURL(for: "swift")?.host == "search.brave.com")
        #expect(SearchEngine.kagi.suggestionURL(for: "swift") == nil && !SearchEngine.kagi.offersSuggestions)
    }

    @Test func newPreferencesKeepTodaysBehaviorAndPersist() throws {
        let (store, suite) = defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: store)
        #expect(preferences.searchEngine == .google, "Existing users keep Google")
        #expect(preferences.showsCommandBarInEmptyWindows && preferences.pinsResetWhenClosed)
        #expect(preferences.controlTabShowsSwitcher)
        #expect(preferences.checksForUpdatesAutomatically && !preferences.installsUpdatesAutomatically)
        #expect(!preferences.shortcuts.hasChanges)

        preferences.searchEngine = .ecosia
        preferences.showsCommandBarInEmptyWindows = false
        preferences.pinsResetWhenClosed = false
        preferences.controlTabShowsSwitcher = false
        preferences.installsUpdatesAutomatically = true
        preferences.shortcuts.assign(BrowserShortcut("k"), to: .newTab)
        preferences.shortcuts.remove(.printPage)
        let reloaded = BrowserPreferences(defaults: store)
        #expect(reloaded.searchEngine == .ecosia && !reloaded.showsCommandBarInEmptyWindows && !reloaded.pinsResetWhenClosed)
        #expect(!reloaded.controlTabShowsSwitcher && reloaded.installsUpdatesAutomatically)
        #expect(reloaded.shortcuts.shortcut(for: .newTab) == BrowserShortcut("k"))
        #expect(reloaded.shortcuts.shortcut(for: .printPage) == nil, "A removed shortcut stays removed")

        // Unreadable values fall back to the defaults rather than failing.
        store.set("altavista", forKey: "searchEngine")
        store.set(Data("not json".utf8), forKey: "keyboardShortcuts")
        let fallback = BrowserPreferences(defaults: store)
        #expect(fallback.searchEngine == .google && !fallback.shortcuts.hasChanges)
    }

    @Test func shortcutsChangeOnlyWhereChosenAndRefuseClashes() throws {
        var shortcuts = BrowserShortcuts()
        #expect(shortcuts.shortcut(for: .newTab)?.display == "⌘T")
        #expect(shortcuts.shortcut(for: .viewPageSource)?.display == "⌥⌘U")
        #expect(shortcuts.shortcut(for: .previousSpace)?.display == "⌥⌘←")
        #expect(shortcuts.shortcut(for: .duplicateTab) == nil, "Some commands start without one")
        #expect(BrowserShortcut("k", [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘K")

        #expect(shortcuts.assign(BrowserShortcut("d", [.command, .shift]), to: .duplicateTab) == nil)
        #expect(shortcuts.shortcut(for: .duplicateTab)?.display == "⇧⌘D" && shortcuts.isChanged(.duplicateTab))
        // Taken, reserved, or without a modifier: refused, with a reason.
        #expect(shortcuts.assign(BrowserShortcut("t"), to: .duplicateTab) == .takenBy(.newTab))
        #expect(shortcuts.shortcut(for: .duplicateTab)?.display == "⇧⌘D")
        #expect(shortcuts.assign(BrowserShortcut("q"), to: .duplicateTab) == .reserved)
        #expect(shortcuts.assign(BrowserShortcut("1"), to: .duplicateTab) == .reserved, "Numbered tabs keep ⌘1–⌘9")
        #expect(shortcuts.assign(BrowserShortcut("tab", .control), to: .duplicateTab) == .reserved)
        #expect(shortcuts.assign(BrowserShortcut("k", []), to: .duplicateTab) == .needsModifier)
        #expect(shortcuts.assign(BrowserShortcut("k", .shift), to: .duplicateTab) == .needsModifier)
        #expect(shortcuts.assign(BrowserShortcut("f5", []), to: .duplicateTab) == nil, "Function keys need no modifier")
        #expect(BrowserShortcuts.Problem.takenBy(.newTab).message.contains("New Tab"))

        // Taking another's shortcut on purpose leaves that one without.
        #expect(shortcuts.assign(BrowserShortcut("t"), to: .duplicateTab, replacing: true) == nil)
        #expect(shortcuts.shortcut(for: .duplicateTab)?.display == "⌘T" && shortcuts.shortcut(for: .newTab) == nil)
        // New Tab can't go back while another command has its key…
        #expect(shortcuts.reset(.newTab) == .takenBy(.duplicateTab))
        shortcuts.reset(.duplicateTab)
        #expect(shortcuts.reset(.newTab) == nil && shortcuts.shortcut(for: .newTab)?.display == "⌘T")
        // …and choosing a command's own default isn't a change.
        #expect(shortcuts.assign(BrowserShortcut("w"), to: .closeTab) == nil && !shortcuts.isChanged(.closeTab))
        shortcuts.remove(.printPage)
        #expect(shortcuts.shortcut(for: .printPage) == nil && shortcuts.isChanged(.printPage))
        shortcuts.resetAll()
        #expect(!shortcuts.hasChanges && shortcuts.shortcut(for: .printPage)?.display == "⌘P")

        // Every default is free to use and no two commands share one.
        let defaults = BrowserCommand.allCases.compactMap(\.defaultShortcut)
        #expect(Set(defaults).count == defaults.count)
        #expect(defaults.allSatisfy { !BrowserShortcuts.reserved.contains($0) })
    }

    @Test func shortcutsAreSavedAsNamedChoices() throws {
        var shortcuts = BrowserShortcuts()
        shortcuts.assign(BrowserShortcut("leftArrow", [.command, .control]), to: .back)
        shortcuts.remove(.printPage)
        let data = try JSONEncoder().encode(shortcuts)
        let json = try #require(try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any])
        #expect(Set(json.keys) == ["back", "printPage"] && json["printPage"] is NSNull)
        #expect(try JSONDecoder().decode(BrowserShortcuts.self, from: data) == shortcuts)
        // A command a later version no longer has is dropped.
        let later = Data(#"{"back":{"key":"[","modifiers":1},"teleport":null}"#.utf8)
        let decoded = try JSONDecoder().decode(BrowserShortcuts.self, from: later)
        #expect(!decoded.hasChanges, "⌘[ is Back's own")
        #expect(BrowserCommand.Group.allCases.flatMap(\.commands).count == BrowserCommand.allCases.count)
    }

    @Test func closingAPinCanKeepItsPage() throws {
        let profile = UUID(), space = UUID()
        let saved = try #require(URL(string: "https://example.com/start"))
        var pin = BrowserTab(spaceID: space, profileID: profile, title: "Start", currentURL: saved, pinnedURL: saved)
        pin.currentURL = try #require(URL(string: "https://example.com/elsewhere"))
        var store = TabStore(tabs: [pin])
        store.close(id: pin.id, in: space, resetsPin: false)
        #expect(store.tab(id: pin.id).map { !$0.isOpen && $0.currentURL.path == "/elsewhere" } == true)
        store.reopen(pin.id)
        store.close(id: pin.id, in: space)
        #expect(store.tab(id: pin.id)?.currentURL == saved, "Resetting is still the default")

        let coordinator = BrowserCoordinator(startup: .returningSession, activeSpaceID: space,
                                             tabStore: TabStore(tabs: [BrowserTab(spaceID: space, profileID: profile, title: "Start",
                                                 currentURL: try #require(URL(string: "https://example.com/elsewhere")), pinnedURL: saved)]),
                                             profileID: profile, spaces: [BrowserSpace(id: space, profileID: profile, name: "One")])
        coordinator.pinsResetWhenClosed = { false }
        let id = try #require(coordinator.tabStore.tabs.first?.id)
        _ = coordinator.openTab(id)
        _ = coordinator.closeTab(id)
        #expect(coordinator.tabStore.tab(id: id)?.currentURL.path == "/elsewhere")
    }

    @Test func permissionsCanAllBeForgotten() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyPermissions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let permissions = SitePermissions(fileURL: file)
        permissions.set(.allow, for: [.camera], origin: "https://meet.example")
        permissions.set(.block, for: [.location], origin: "https://maps.example")
        permissions.removeAll()
        #expect(permissions.decisions.isEmpty)
        #expect(SitePermissions(fileURL: file).decisions.isEmpty, "Saved too")
    }
}
