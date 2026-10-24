// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import EarlyCore
import Observation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// Early's updates, from its GitHub releases through Sparkle. Each update is
/// signed with Early's update key, checks follow Settings, and an update
/// installs only when the person agrees, unless they chose automatic
/// installs. Development builds, tests and UI automation never check.
@MainActor @Observable
final class SoftwareUpdater {
    /// Whether this copy of Early updates itself at all.
    let isAvailable: Bool
    /// False while a check is already showing or under way.
    private(set) var canCheck = false
    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscription: AnyCancellable?
    #endif

    init(preferences: BrowserPreferences, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if canImport(Sparkle) && !DEBUG
        isAvailable = environment["EARLY_TEST_DEFAULTS_SUITE"] == nil
        #else
        isAvailable = false
        #endif
        #if canImport(Sparkle)
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Set before starting, so Sparkle never asks: Settings is where it's chosen.
        apply(preferences)
        controller.startUpdater()
        subscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheck = value } }
        #endif
    }

    /// Settings › General's choices.
    func apply(_ preferences: BrowserPreferences) {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = preferences.checksForUpdatesAutomatically
        updater.automaticallyDownloadsUpdates = preferences.checksForUpdatesAutomatically && preferences.installsUpdatesAutomatically
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    /// "0.2.0 (148)".
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Development"
        return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }
}

/// Settings › General: how Early updates itself.
struct UpdatesCard: View {
    let updater: SoftwareUpdater
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        SettingsCard {
            SettingsToggle("Check for updates automatically", detail: "Early looks for a new version on GitHub once a day. It sends only its own version, never your browsing.", isOn: $preferences.checksForUpdatesAutomatically, identifier: "settings.checksForUpdates")
            Divider().padding(.vertical, 6)
            SettingsToggle("Install updates automatically", detail: "Download new versions in the background and install them when you quit Early. When this is off, Early asks first.", isOn: $preferences.installsUpdatesAutomatically, identifier: "settings.installsUpdates")
                .disabled(!preferences.checksForUpdatesAutomatically)
            HStack {
                Text("Version \(SoftwareUpdater.currentVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                    .accessibilityIdentifier("settings.checkForUpdates")
            }
        }
    }
}
