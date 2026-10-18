// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct SpaceAppearanceTests {
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
}
