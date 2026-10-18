// SPDX-License-Identifier: MPL-2.0

@testable import EarlyWeb
import Testing

struct BrowserUserAgentTests {
    @Test func identityHasSafariCompatibilityAndEarlyTokens() {
        let identity = BrowserUserAgent.make(operatingSystemMajorVersion: 27,
            safariVersion: "27.0.1", appVersion: "0.2.3")
        #expect(identity == "Version/27.0.1 Safari/605.1.15 Early/0.2.3")
        #expect(!identity.contains("Chrome/"))
    }

    @Test(arguments: [(14, "17.0"), (15, "18.0"), (26, "26.0"), (27, "27.0"), (99, "27.0")])
    func missingSafariUsesKnownBaseline(osMajor: Int, expected: String) {
        let identity = BrowserUserAgent.make(operatingSystemMajorVersion: osMajor,
            safariVersion: nil, appVersion: nil)
        #expect(identity.hasPrefix("Version/\(expected) Safari/"))
        #expect(identity.hasSuffix(" Early/0.1.0"))
    }

    @Test func installedUpdateOnOlderMacOSIsUsedWithoutDowngradingNewerMacOS() {
        let updated = BrowserUserAgent.make(operatingSystemMajorVersion: 14,
            safariVersion: "26.1", appVersion: "1.0")
        #expect(updated.hasPrefix("Version/26.1 Safari/"))
        let stale = BrowserUserAgent.make(operatingSystemMajorVersion: 27,
            safariVersion: "17.6", appVersion: "1.0")
        #expect(stale.hasPrefix("Version/27.0 Safari/"))
    }

    @Test(arguments: ["", "27..1", ".27", "27.", "27.0 beta", "27.0\r\nInjected: true",
                      "27.0 Safari/999", "٢٧.٠", String(repeating: "9", count: 33)])
    func malformedMetadataCannotChangeBrowserTokens(value: String) {
        let identity = BrowserUserAgent.make(operatingSystemMajorVersion: 26,
            safariVersion: value, appVersion: value)
        #expect(identity.hasPrefix("Version/26.0 Safari/605.1.15"))
        #expect(identity.hasSuffix(" Early/0.1.0"))
        #expect(!identity.contains("\r"))
        #expect(!identity.contains("\n"))
    }
}
