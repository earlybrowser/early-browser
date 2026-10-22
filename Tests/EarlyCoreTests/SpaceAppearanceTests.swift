// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SpaceAppearanceTests {
    private static func luminance(_ rgb: SpaceThemeRGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private static func ratio(_ first: SpaceThemeRGB, _ second: SpaceThemeRGB) -> Double {
        let left = luminance(first), right = luminance(second)
        return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }

    @Test func focusedBordersAreMutedAndReadableAgainstLightAndDarkSurfaces() {
        let ratio = Self.ratio
        for theme in BrowserSpace.Color.allCases {
            for dark in [false, true] {
                let page = dark ? SpaceThemeRGB(red: 0.125, green: 0.129, blue: 0.141)
                    : SpaceThemeRGB(red: 1, green: 1, blue: 1)
                let normal = theme.focusBorder(isDark: dark)
                for increased in [false, true] {
                    let edge = theme.focusBorder(isDark: dark, increasedContrast: increased)
                    let channels = [edge.red, edge.green, edge.blue]
                    #expect(channels.allSatisfy { $0.isFinite && (0...1).contains($0) })
                    #expect(ratio(edge, page) >= 3)
                    #expect(ratio(edge, theme.chromeTop(isDark: dark)) >= 3)
                    #expect(ratio(edge, theme.chromeBottom(isDark: dark)) >= 3)
                    #expect(!increased || ratio(edge, page) >= ratio(normal, page))
                    if theme == .gray {
                        #expect(edge.red == edge.green && edge.green == edge.blue)
                    } else {
                        let swatch = theme.swatch
                        let original = [swatch.red, swatch.green, swatch.blue]
                        #expect(edge != swatch)
                        #expect(channels.max()! - channels.min()! < original.max()! - original.min()!)
                        #expect((edge.red < edge.blue) == (swatch.red < swatch.blue))
                    }
                }
                #expect(theme.focusBorder(isDark: true) != theme.focusBorder(isDark: false))
            }
        }
    }

    @Test func folderLayersFollowTheirThemeInBothAppearances() {
        for color in BrowserSpace.Color.allCases {
            for dark in [false, true] {
                let front = color.folderFront(isDark: dark)
                let back = color.folderBack(isDark: dark)
                let frontChannels = [front.red, front.green, front.blue]
                let backChannels = [back.red, back.green, back.blue]
                #expect((frontChannels + backChannels).allSatisfy { (0...1).contains($0) })
                #expect(zip(frontChannels, backChannels).allSatisfy { dark ? $0 < $1 : $0 > $1 })
                if color == .gray {
                    #expect(front.red == front.green && front.green == front.blue)
                    #expect(back.red == back.green && back.green == back.blue)
                    #expect(front.red == (dark ? 0.13 : 0.95))
                    #expect(back.red == (dark ? 0.47 : 0.72))
                } else {
                    #expect(front != BrowserSpace.Color.gray.folderFront(isDark: dark))
                    #expect(back != BrowserSpace.Color.gray.folderBack(isDark: dark))
                    #expect((front.red < front.blue) == (color.swatch.red < color.swatch.blue))
                    #expect((back.red < back.green) == (color.swatch.red < color.swatch.green))
                }
            }
        }
    }

    @Test func oldSpacePayloadsWithoutIconsKeepTheirIdentityAndTheme() throws {
        let space = BrowserSpace(profileID: UUID(), name: "Existing", color: .purple)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(space)) as? [String: Any])
        payload.removeValue(forKey: "icon")
        let restored = try JSONDecoder().decode(BrowserSpace.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored == space)
        #expect(restored.icon == nil && restored.color == .purple)
    }

    @Test func symbolsRoundTripWithoutChangingTheme() throws {
        let icons = SpaceIcon.Symbol.allCases.map { SpaceIcon.symbol($0) }
        for icon in icons {
            let space = BrowserSpace(profileID: UUID(), name: "Work", color: .green, icon: icon)
            #expect(try JSONDecoder().decode(BrowserSpace.self, from: JSONEncoder().encode(space)) == space)
        }
        #expect(Set(SpaceIcon.Symbol.allCases.map(\.rawValue)).count == SpaceIcon.Symbol.allCases.count)
    }

    @Test func retiredEmojiAndUnknownIconsFallBackWithoutLosingSavedPages() throws {
        var session = BrowserSession()
        let tab = BrowserTab(spaceID: session.activeSpaceID, profileID: session.profileID,
            title: "Keep this page", currentURL: URL(string: "https://example.com")!)
        session.tabs = [tab]
        session.selectionBySpace = [session.activeSpaceID: tab.id]
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        let icons: [Any] = [["emoji": ["_0": "😀"]], ["symbol": ["_0": "not-a-symbol"]], "invalid-icon", NSNull()]
        for icon in icons {
            var payload = original
            var spaces = try #require(payload["spaces"] as? [[String: Any]])
            spaces[0]["icon"] = icon
            payload["spaces"] = spaces
            let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: payload))
            try restored.validate()
            #expect(restored == session)
            #expect(restored.spaces.first?.icon == nil)
        }
    }

    @Test @MainActor func appearanceEditsDuplicateAndSynchronizeWithoutChangingLiveSelection() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let original = browser.activeSpaceID
        let url = URL(string: "https://example.com")!
        let tab = try #require(browser.navigate(to: url, target: .newTab(spaceID: original)))
        let child = BrowserCoordinator(startup: .returningSession, activeSpaceID: original,
            profileID: browser.profileID, spaces: browser.spaces)
        #expect(browser.editSpace(original, name: "Personal", color: .pink, icon: .symbol(.heart)))
        #expect(browser.activeTabID == tab)
        #expect(browser.editSpace(original, name: "Home", color: .purple))
        #expect(browser.activeSpace?.icon == .symbol(.heart))
        let copy = try #require(browser.duplicateSpace(original, name: "Copy"))
        #expect(browser.spaces.first { $0.id == copy }?.icon == .symbol(.heart))
        #expect(browser.spaces.first { $0.id == copy }?.color == .purple)
        child.synchronizeSavedItems(from: browser.session)
        #expect(child.spaces == browser.spaces)
        #expect(browser.editSpace(original, name: "Home", color: .green, icon: .symbol(.leaf)))
        child.synchronizeSavedItems(from: browser.session)
        #expect(child.activeSpace?.icon == .symbol(.leaf))
        #expect(child.activeSpace?.color == .green)
        let before = browser.session
        #expect(!browser.editSpace(original, name: "", color: .red, icon: .symbol(.star)))
        #expect(browser.createSpace(name: "", icon: .symbol(.star)) == nil)
        #expect(browser.session == before)
        #expect(browser.editSpace(original, name: "Home", color: .green, icon: nil))
        #expect(browser.activeSpace?.icon == nil && browser.activeTabID == tab)
        try browser.session.validate()
    }

    @Test @MainActor func iconAndThemePersistThroughTheActualSnapshotWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyAppearance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.sqlite")
        let browser = BrowserCoordinator(startup: .returningSession)
        _ = try #require(browser.createSpace(name: "Code", color: .purple, icon: .symbol(.terminal)))
        let garden = try #require(browser.createSpace(name: "Garden", color: .green, icon: .symbol(.leaf)))
        browser.switchSpace(to: garden)
        let snapshot = browser.session
        try await SessionRepository(fileURL: file).save(snapshot, revision: 1)
        let restored = try #require(try await SessionRepository(fileURL: file).load())
        #expect(restored == snapshot)
        #expect(restored.spaces.last?.icon == .symbol(.leaf))
        #expect(restored.spaces.last?.color == .green)
    }

    @Test func appliedThemesAreDarkOrLightWhileSwatchesStayUnchanged() {
        for color in BrowserSpace.Color.allCases {
            let swatch = color.swatch
            for dark in [true, false] {
                for rgb in [color.chromeTop(isDark: dark), color.chromeBottom(isDark: dark)] {
                    let channels = [rgb.red, rgb.green, rgb.blue]
                    #expect(channels.allSatisfy { $0.isFinite && (0...1).contains($0) })
                    #expect(dark ? channels.allSatisfy { $0 < 0.15 } : channels.allSatisfy { $0 > 0.65 })
                    #expect(channels.max()! - channels.min()! < (dark ? 0.10 : 0.30))
                    #expect(rgb != swatch)
                }
                #expect(color.swatch == swatch)
            }
            #expect(color.chromeTop(isDark: true) != color.chromeTop(isDark: false))
        }
        #expect(BrowserSpace.Color.blue.swatch.blue > BrowserSpace.Color.blue.swatch.red)
        #expect(BrowserSpace.Color.green.swatch.green > BrowserSpace.Color.green.swatch.red)
        let cream = BrowserSpace.Color.gray.chromeTop(isDark: false)
        #expect(cream.red - cream.blue > 0.02)
        let butter = BrowserSpace.Color.yellow.chromeTop(isDark: false)
        #expect(butter.red - butter.blue > 0.20)
        let blue = BrowserSpace.Color.blue.chromeTop(isDark: false)
        #expect(blue.blue - blue.red > 0.15)
        let darkBlue = BrowserSpace.Color.blue.chromeTop(isDark: true)
        #expect(darkBlue.blue - darkBlue.red > 0.085)
        let darkBlueBottom = BrowserSpace.Color.blue.chromeBottom(isDark: true)
        #expect(darkBlueBottom.blue - darkBlueBottom.red > 0.05)
    }

    @Test func privateWindowsUseOneDarkGrayLighterThanDarkChromeThatNoSpaceCanChoose() {
        let theme = WindowTheme.privateBrowsing
        let top = theme.chromeTop(isDark: false), bottom = theme.chromeBottom(isDark: false)
        #expect(theme.chromeTop(isDark: true) == top && theme.chromeBottom(isDark: true) == bottom, "The same in both appearances")
        #expect(theme.focusBorder(isDark: true) == theme.focusBorder(isDark: false))
        for rgb in [top, bottom] {
            #expect(max(rgb.red, rgb.green, rgb.blue) - min(rgb.red, rgb.green, rgb.blue) < 0.03, "A gray, barely cool")
            #expect(rgb.blue > rgb.red)
            #expect(Self.ratio(rgb, SpaceThemeRGB(red: 1, green: 1, blue: 1)) >= 7, "White text reads clearly on it")
            #expect(Self.ratio(rgb, SpaceThemeRGB(red: 0, green: 0, blue: 0)) < 3, "So its chrome is drawn dark")
            let edge = theme.focusBorder(isDark: true), strong = theme.focusBorder(isDark: true, increasedContrast: true)
            #expect(Self.ratio(edge, rgb) >= 3 && Self.ratio(strong, rgb) >= 4.5)
            #expect(Self.ratio(strong, rgb) > Self.ratio(edge, rgb))
        }
        for color in BrowserSpace.Color.allCases {
            // Lighter than every Space's dark chrome, and nothing like its light chrome.
            #expect(Self.luminance(top) > Self.luminance(color.chromeTop(isDark: true)))
            #expect(Self.ratio(top, color.chromeTop(isDark: true)) >= 1.3)
            #expect(Self.ratio(bottom, color.chromeBottom(isDark: true)) >= 1.3)
            #expect(Self.ratio(top, color.chromeTop(isDark: false)) >= 5)
        }
        #expect(BrowserSpace.Color.allCases.map(\.rawValue) == ["gray", "blue", "purple", "pink", "red", "orange", "yellow", "green"],
                "The private gray is not a Space or profile color")
        #expect(BrowserSession.privateWindow().spaces.first?.color == .gray)
        for color in BrowserSpace.Color.allCases {
            for dark in [false, true] {
                let space = WindowTheme.space(color)
                #expect(space.chromeTop(isDark: dark) == color.chromeTop(isDark: dark))
                #expect(space.chromeBottom(isDark: dark) == color.chromeBottom(isDark: dark))
                #expect(space.focusBorder(isDark: dark, increasedContrast: true) == color.focusBorder(isDark: dark, increasedContrast: true))
                #expect(space.chromeTop(isDark: dark) != top)
            }
            #expect(WindowTheme.space(color).swatch == color.swatch && WindowTheme.space(color) != theme)
        }
    }
}
