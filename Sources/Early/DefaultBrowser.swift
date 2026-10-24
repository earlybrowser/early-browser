// SPDX-License-Identifier: MPL-2.0

import AppKit

/// Which app opens web links, and asking macOS to make it Early. macOS asks
/// the person before anything changes.
struct DefaultBrowser {
    var isDefault: @MainActor () -> Bool
    var makeDefault: @MainActor () async -> Void

    @MainActor static var system: DefaultBrowser {
        func handler(_ scheme: String) -> URL? {
            URL(string: "\(scheme)://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }
        let early = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return DefaultBrowser(isDefault: {
            ["http", "https"].allSatisfy { handler($0)?.resolvingSymlinksInPath() == early }
        }, makeDefault: {
            // Choosing it for http normally covers https too; ask again only if not.
            for scheme in ["http", "https"] where handler(scheme)?.resolvingSymlinksInPath() != early {
                do { try await NSWorkspace.shared.setDefaultApplication(at: early, toOpenURLsWithScheme: scheme) }
                catch { return }
            }
        })
    }

    /// Never the default, and never asks: for tests and UI automation.
    static var unavailable: DefaultBrowser { DefaultBrowser(isDefault: { false }, makeDefault: {}) }
}
