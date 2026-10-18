// SPDX-License-Identifier: MPL-2.0

import Foundation

/// macOS WKWebView's default identity omits Safari's Version/Safari tokens,
/// causing some sites to serve legacy layouts. This is a compatibility label,
/// not an assertion of Safari-only features or the exact WebKit engine version.
enum BrowserUserAgent {
    // Resolve once without allocating a web view, launching Safari, or reading
    // browsing data. Missing/inaccessible Safari metadata uses the OS baseline.
    static let applicationName = make(
        operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        safariVersion: installedSafariVersion(),
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    static func make(operatingSystemMajorVersion: Int, safariVersion: String?, appVersion: String?) -> String {
        let baseline = safariBaseline(for: operatingSystemMajorVersion)
        // Safari updates can bring newer WebKit to older macOS releases. Prefer
        // installed Safari metadata, but never downgrade below the OS baseline.
        let installed = versionToken(safariVersion)
        let compatibility = installed.flatMap {
            $0.compare(baseline, options: .numeric) == .orderedAscending ? nil : $0
        } ?? baseline
        let earlyVersion = versionToken(appVersion) ?? "0.1.0"
        // WebKit generates the platform/engine prefix. Only supply the browser
        // compatibility suffix; never replace navigator.userAgent with a script.
        return "Version/\(compatibility) Safari/605.1.15 Early/\(earlyVersion)"
    }

    private static func installedSafariVersion() -> String? {
        // These are best-effort bundle locations, not a WebKit API contract.
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            guard let safari = Bundle(path: path), safari.bundleIdentifier == "com.apple.Safari",
                  let version = versionToken(safari.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            else { continue }
            return version
        }
        return nil
    }

    private static func safariBaseline(for osMajor: Int) -> String {
        // Known release baselines, not an OS-to-Safari version formula:
        // Sonoma 14 -> Safari 17; Sequoia 15 -> Safari 18; 26 -> 26; 27 -> 27.
        // Future OS releases retain the latest known baseline until reviewed.
        switch osMajor {
        case 27...: "27.0"
        case 26...: "26.0"
        case 15...: "18.0"
        default: "17.0" // Early's minimum supported macOS is 14.
        }
    }

    private static func versionToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 32 else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count), components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        return value
    }
}
