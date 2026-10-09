import Foundation

/// Only a first-use preference is stored in Phase 0. It is not inferred from
/// tab count and does not stand in for session persistence or onboarding.
@MainActor
public final class FirstLaunchStore {
    private let defaults: UserDefaults
    private let key = "hasPresentedFirstBrowserWindow"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func claimStartupContext() -> StartupContext {
        if defaults.bool(forKey: key) { return .returningSession }
        defaults.set(true, forKey: key)
        return .firstLaunch
    }
}
