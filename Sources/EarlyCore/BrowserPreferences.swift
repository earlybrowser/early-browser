// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

@MainActor @Observable
public final class BrowserPreferences {
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public var onChange: (() -> Void)?

    public var appearance: Appearance { didSet { store(appearance.rawValue, for: "browserAppearance") } }
    public var onlineSuggestions: Bool { didSet { store(onlineSuggestions, for: "onlineSearchSuggestions") } }
    public var sidebarAutoHides: Bool { didSet { store(sidebarAutoHides, for: "sidebarAutoHides") } }
    public var spaceSwipes: Bool { didSet { store(spaceSwipes, for: "spaceSwipes") } }
    public var haptics: Bool { didSet { store(haptics, for: "haptics") } }
    public var spaceThemes: Bool { didSet { store(spaceThemes, for: "spaceThemes") } }
    public var translucentChrome: Bool { didSet { store(translucentChrome, for: "translucentChrome") } }
    public var restoreSession: Bool { didSet { store(restoreSession, for: "restoreSession") } }
    private var width: Double

    public var sidebarWidth: Double {
        get { width }
        set {
            width = SidebarWidth.clamped(newValue)
            store(width, for: "sidebarWidth")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["onlineSearchSuggestions": true, "spaceSwipes": true,
            "haptics": true, "spaceThemes": true, "translucentChrome": true, "restoreSession": true])
        appearance = Appearance(rawValue: defaults.string(forKey: "browserAppearance") ?? "") ?? .system
        onlineSuggestions = defaults.bool(forKey: "onlineSearchSuggestions")
        sidebarAutoHides = defaults.bool(forKey: "sidebarAutoHides")
        spaceSwipes = defaults.bool(forKey: "spaceSwipes")
        haptics = defaults.bool(forKey: "haptics")
        spaceThemes = defaults.bool(forKey: "spaceThemes")
        translucentChrome = defaults.bool(forKey: "translucentChrome")
        restoreSession = defaults.bool(forKey: "restoreSession")
        width = SidebarWidth.clamped(defaults.object(forKey: "sidebarWidth") as? Double ?? SidebarWidth.defaultValue)
    }

    private func store(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
