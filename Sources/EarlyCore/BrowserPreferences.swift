// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

@MainActor @Observable
public final class BrowserPreferences {
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public var onChange: ((String) -> Void)?

    public var appearance: Appearance { didSet { store(appearance.rawValue, for: "browserAppearance") } }
    public var onlineSuggestions: Bool { didSet { store(onlineSuggestions, for: "onlineSearchSuggestions") } }
    public var commandBarActions: Bool { didSet { store(commandBarActions, for: "commandBarActions") } }
    /// Off by default: what is typed in a private window stays local until searched.
    public var privateOnlineSuggestions: Bool { didSet { store(privateOnlineSuggestions, for: "privateSearchSuggestions") } }
    public var sidebarAutoHides: Bool { didSet { store(sidebarAutoHides, for: "sidebarAutoHides") } }
    public var spaceSwipes: Bool { didSet { store(spaceSwipes, for: "spaceSwipes") } }
    public var haptics: Bool { didSet { store(haptics, for: "haptics") } }
    public var spaceThemes: Bool { didSet { store(spaceThemes, for: "spaceThemes") } }
    public var translucentChrome: Bool { didSet { store(translucentChrome, for: "translucentChrome") } }
    public var restoreSession: Bool { didSet { store(restoreSession, for: "restoreSession") } }
    /// A video playing in a tab you switch away from continues in Picture in Picture.
    public var automaticPictureInPicture: Bool { didSet { store(automaticPictureInPicture, for: "automaticPictureInPicture") } }
    /// Where command-bar searches and their suggestions go.
    public var searchEngine: SearchEngine { didSet { store(searchEngine.rawValue, for: "searchEngine") } }
    /// A window that opens without a tab shows the command bar, ready to type.
    /// Early's very first launch always does.
    public var showsCommandBarInEmptyWindows: Bool {
        didSet { store(showsCommandBarInEmptyWindows, for: "showsCommandBarInEmptyWindows") }
    }
    /// Closing a pin or Favorite returns it to its saved page; off, it keeps
    /// the page it was on (Reset to Pinned URL still returns it).
    public var pinsResetWhenClosed: Bool { didSet { store(pinsResetWhenClosed, for: "pinsResetWhenClosed") } }
    /// Control-Tab shows the tab switcher; off, it steps through tabs in sidebar order.
    public var controlTabShowsSwitcher: Bool { didSet { store(controlTabShowsSwitcher, for: "controlTabShowsSwitcher") } }
    /// How Early updates itself (Sparkle). Settings shows them only in
    /// releases, the only builds that update.
    public var checksForUpdatesAutomatically: Bool {
        didSet { store(checksForUpdatesAutomatically, for: "checksForUpdatesAutomatically") }
    }
    public var installsUpdatesAutomatically: Bool {
        didSet { store(installsUpdatesAutomatically, for: "installsUpdatesAutomatically") }
    }
    /// Shortcuts the person changed or removed; every other command keeps its own.
    public var shortcuts: BrowserShortcuts {
        didSet { if let data = try? JSONEncoder().encode(shortcuts) { store(data, for: "keyboardShortcuts") } }
    }
    private var width: Double

    public var sidebarWidth: Double {
        get { width }
        set {
            width = SidebarWidth.clamped(newValue)
            store(width, for: "sidebarWidth")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        // Saved accounts now require an explicit choice in the field's picker.
        defaults.removeObject(forKey: "fillsPasswordsAutomatically")
        self.defaults = defaults
        defaults.register(defaults: ["onlineSearchSuggestions": true, "commandBarActions": true, "spaceSwipes": true,
            "haptics": true, "spaceThemes": true, "translucentChrome": true, "restoreSession": true,
            "automaticPictureInPicture": true, "showsCommandBarInEmptyWindows": true,
            "pinsResetWhenClosed": true, "controlTabShowsSwitcher": true,
            "checksForUpdatesAutomatically": true])
        appearance = Appearance(rawValue: defaults.string(forKey: "browserAppearance") ?? "") ?? .system
        onlineSuggestions = defaults.bool(forKey: "onlineSearchSuggestions")
        commandBarActions = defaults.bool(forKey: "commandBarActions")
        privateOnlineSuggestions = defaults.bool(forKey: "privateSearchSuggestions")
        sidebarAutoHides = defaults.bool(forKey: "sidebarAutoHides")
        spaceSwipes = defaults.bool(forKey: "spaceSwipes")
        haptics = defaults.bool(forKey: "haptics")
        spaceThemes = defaults.bool(forKey: "spaceThemes")
        translucentChrome = defaults.bool(forKey: "translucentChrome")
        restoreSession = defaults.bool(forKey: "restoreSession")
        automaticPictureInPicture = defaults.bool(forKey: "automaticPictureInPicture")
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google
        showsCommandBarInEmptyWindows = defaults.bool(forKey: "showsCommandBarInEmptyWindows")
        pinsResetWhenClosed = defaults.bool(forKey: "pinsResetWhenClosed")
        controlTabShowsSwitcher = defaults.bool(forKey: "controlTabShowsSwitcher")
        checksForUpdatesAutomatically = defaults.bool(forKey: "checksForUpdatesAutomatically")
        installsUpdatesAutomatically = defaults.bool(forKey: "installsUpdatesAutomatically")
        // An unreadable list never takes anyone's shortcuts away: the defaults apply.
        shortcuts = defaults.data(forKey: "keyboardShortcuts").flatMap { try? JSONDecoder().decode(BrowserShortcuts.self, from: $0) }
            ?? BrowserShortcuts()
        width = SidebarWidth.clamped(defaults.object(forKey: "sidebarWidth") as? Double ?? SidebarWidth.defaultValue)
    }

    private func store(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        onChange?(key)
    }
}
