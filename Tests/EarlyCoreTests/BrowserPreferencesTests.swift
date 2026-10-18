// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct BrowserPreferencesTests {
    @Test func settingsPersistAndMigrateExistingKeysInAnIsolatedDomain() throws {
        let suite = "local.early.tests.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "onlineSearchSuggestions")
        defaults.set(300, forKey: "sidebarWidth")
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(!preferences.onlineSuggestions && preferences.sidebarWidth == 300)
        #expect(preferences.spaceSwipes && preferences.haptics && preferences.spaceThemes && preferences.translucentChrome)
        preferences.appearance = .dark
        preferences.sidebarAutoHides = true
        preferences.spaceSwipes = false
        preferences.haptics = false
        preferences.restoreSession = false
        preferences.spaceThemes = false
        preferences.translucentChrome = false
        preferences.onlineSuggestions = true
        let restored = BrowserPreferences(defaults: defaults)
        #expect(restored.appearance == .dark && restored.sidebarAutoHides)
        #expect(!restored.spaceSwipes && !restored.haptics && !restored.restoreSession)
        #expect(!restored.spaceThemes && !restored.translucentChrome && restored.onlineSuggestions)
        restored.sidebarWidth = .infinity
        #expect(restored.sidebarWidth == SidebarWidth.defaultValue)
        restored.sidebarWidth = 9999
        #expect(restored.sidebarWidth == SidebarWidth.maximum)
        defaults.set("unsupported", forKey: "browserAppearance")
        #expect(BrowserPreferences(defaults: defaults).appearance == .system)
    }
}
