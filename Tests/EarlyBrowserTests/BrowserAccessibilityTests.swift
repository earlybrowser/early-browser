// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import SwiftUI
import Testing

/// Headless checks only: no VoiceOver activation, system preference writes,
/// synthesized input, visible windows, or desktop screenshots.
@Suite(.serialized) @MainActor
struct BrowserAccessibilityTests {
    private func tab(pinned: Bool = false, favorite: Bool = false, open: Bool = true) -> BrowserTab {
        let url = URL(string: "early-test://fixture/one")!
        return BrowserTab(spaceID: UUID(), profileID: UUID(), title: "Page", currentURL: url,
            pinnedURL: pinned || favorite ? url : nil, isOpen: open, isFavorite: favorite)
    }

    @Test func spokenStatusDistinguishesSavedClosedLoadingFailedAndMutedPages() {
        #expect(BrowserTabAccessibility.value(for: tab()) == "Today")
        #expect(BrowserTabAccessibility.value(for: tab(pinned: true)) == "Pinned, open")
        #expect(BrowserTabAccessibility.value(for: tab(favorite: true)) == "Favorite, open")
        #expect(BrowserTabAccessibility.value(for: tab(pinned: true, open: false), isLoading: true,
            hasFailure: true, isMuted: true, isPlayingMedia: true) == "Pinned, closed")
        #expect(BrowserTabAccessibility.value(for: tab(favorite: true, open: false)) == "Favorite, closed")
        #expect(BrowserTabAccessibility.value(for: tab(), isLoading: true, isPlayingMedia: true) == "Today, media playing, loading")
        #expect(BrowserTabAccessibility.value(for: tab(pinned: true), hasFailure: true) == "Pinned, open, load failed")
        #expect(BrowserTabAccessibility.value(for: tab(), isMuted: true, isPlayingMedia: true) == "Today, muted")
    }

    @Test func customActionsSupplementSelectionWithoutInventingLiveSavedPages() {
        let ordinary = tab()
        let actions = BrowserTabAccessibility.actions(for: ordinary, isMuted: false, hasMedia: true)
        #expect(actions.map(\.title) == ["Rename Tab", "Close Tab", "Mute Tab", "Move Up", "Move Down"])
        #expect(actions.map(\.action) == [.requestRename(ordinary.id), .closeTab(ordinary.id),
            .setMuted(ordinary.id, true), .moveTabBy(ordinary.id, -1), .moveTabBy(ordinary.id, 1)])
        #expect(Set(actions.map(\.id)).count == actions.count)
        let closed = tab(favorite: true, open: false)
        let closedActions = BrowserTabAccessibility.actions(for: closed, isMuted: true, hasMedia: true)
        #expect(closedActions.map(\.title) == ["Rename Tab", "Move Up", "Move Down"])
        var detour = tab(pinned: true)
        detour.currentURL = URL(string: "early-test://fixture/two")!
        let detourActions = BrowserTabAccessibility.actions(for: detour, isMuted: true, hasMedia: true)
        #expect(detourActions.contains { $0.action == .resetPinnedTab(detour.id) })
        #expect(detourActions.contains { $0.title == "Unmute Tab" && $0.action == .setMuted(detour.id, false) })
        #expect(!BrowserTabAccessibility.actions(for: tab(pinned: true), isMuted: false, hasMedia: false)
            .contains { $0.title == "Reset to Pinned URL" || $0.title == "Mute Tab" })
    }

    @Test func actionDiscoveryIsReadOnlyAndRespectsTheSharedModalAndOwnershipGates() throws {
        _ = NSApplication.shared
        let suite = "local.early.tests.accessibility.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "onlineSearchSuggestions")
        defaults.set(false, forKey: "haptics")
        let saved = tab(pinned: true, open: false)
        let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
        let session = BrowserSession(profileID: saved.profileID, activeSpaceID: saved.spaceID, tabs: [saved])
        let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("EarlyAccessibility-\(UUID()).sqlite"), input: input)
        let model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
            input: input, isTesting: true, restorationError: nil, defaults: defaults)
        defer {
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }
        let initial = model.coordinator.session, focus = model.contentFocusRequest
        for _ in 0..<50 {
            let actions = BrowserTabAccessibility.availableActions(for: saved, in: model)
            #expect(actions.map(\.action) == [.requestRename(saved.id)])
        }
        #expect(model.coordinator.session == initial && model.contentFocusRequest == focus)
        #expect(model.webViews.creationCount == 0 && model.webViews.liveViewCount == 0)
        #expect(BrowserTabAccessibility.availableActions(for: tab(), in: model).isEmpty)
        model.sidebarInteractionInProgress = true
        #expect(BrowserTabAccessibility.availableActions(for: saved, in: model).isEmpty)
        model.sidebarInteractionInProgress = false
        let action = try #require(BrowserTabAccessibility.availableActions(for: saved, in: model).first)
        #expect(model.perform(action.action))
        #expect(model.renamingTabID == saved.id)
        #expect(BrowserTabAccessibility.availableActions(for: saved, in: model).isEmpty)
        #expect(!model.perform(action.action), "A stale custom action cannot bypass an open editor")
        #expect(model.webViews.creationCount == 0)
    }

    @Test func sidebarArrowsAdjustOnlyTheirFocusedControlAndLeaveModifiedKeysAlone() {
        #expect(SidebarKeyboardResize.delta(for: .leftArrow, modifiers: []) == -16)
        #expect(SidebarKeyboardResize.delta(for: .rightArrow, modifiers: .shift) == 16)
        for modifiers: EventModifiers in [.command, .control, .option, [.control, .option], [.command, .shift]] {
            #expect(SidebarKeyboardResize.delta(for: .leftArrow, modifiers: modifiers) == nil)
            #expect(SidebarKeyboardResize.delta(for: .rightArrow, modifiers: modifiers) == nil)
        }
        for key: KeyEquivalent in [.tab, .escape, .space, "t"] {
            #expect(SidebarKeyboardResize.delta(for: key, modifiers: []) == nil)
        }
        #expect(SidebarWidth.clamped(SidebarWidth.minimum - 16) == SidebarWidth.minimum)
        #expect(SidebarWidth.clamped(SidebarWidth.maximum + 16) == SidebarWidth.maximum)
    }

    @Test func reducedMotionClearsInheritedAnimationsWithoutChangingNormalTransactions() {
        var normal = Transaction(animation: .spring())
        BrowserMotionPolicy.apply(to: &normal, reduceMotion: false)
        #expect(normal.animation != nil && !normal.disablesAnimations)
        var reduced = Transaction(animation: .easeInOut(duration: 2))
        BrowserMotionPolicy.apply(to: &reduced, reduceMotion: true)
        #expect(reduced.animation == nil && reduced.disablesAnimations)
        BrowserMotionPolicy.apply(to: &reduced, reduceMotion: false)
        #expect(reduced.animation == nil && reduced.disablesAnimations, "Never re-enable motion disabled by an ancestor")
    }

    @Test(arguments: BrowserSpace.Color.allCases)
    func pickerSelectionCheckmarksHaveStrongContrastOnEverySwatch(_ theme: BrowserSpace.Color) {
        let luminance = BrowserChoiceContrast.luminance(of: theme.swatch)
        let dark = BrowserChoiceContrast.usesDarkMark(on: theme.swatch)
        let contrast = dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
        #expect(contrast >= 4.5)
        if theme == .yellow { #expect(dark, "A white mark was difficult to see on yellow") }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func focusOutlineIsOpaqueAppearanceAwareAndThickerWithIncreasedContrast(_ scheme: ColorScheme) throws {
        _ = NSApplication.shared
        func bitmap(focused: Bool, increased: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: BrowserFocusOutline.Stroke(focused: focused, cornerRadius: 7, increasedContrast: increased)
                .frame(width: 80, height: 40)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            return try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }
        let plain = try bitmap(focused: false, increased: false)
        let focus = try bitmap(focused: true, increased: false)
        let contrast = try bitmap(focused: true, increased: true)
        #expect(plain.pixelsWide == focus.pixelsWide && focus.pixelsWide == contrast.pixelsWide)
        #expect((plain.colorAt(x: 80, y: 0)?.alphaComponent ?? 1) == 0)
        let color = try #require(focus.colorAt(x: 80, y: 1)?.usingColorSpace(.sRGB))
        #expect(color.alphaComponent > 0.99)
        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
        #expect(scheme == .dark ? brightness > 0.8 : brightness < 0.2)
        #expect((focus.colorAt(x: 80, y: 4)?.alphaComponent ?? 1) == 0)
        #expect((contrast.colorAt(x: 80, y: 4)?.alphaComponent ?? 0) > 0.99)
        #expect((contrast.colorAt(x: 80, y: 6)?.alphaComponent ?? 1) == 0)
        #expect((focus.colorAt(x: 80, y: 40)?.alphaComponent ?? 1) == 0, "Focus does not fill or tint the control")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func currentSpaceHasANonColorCueWithStableDimensions(_ scheme: ColorScheme) throws {
        func bitmap(selected: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: BrowserSelectionMark(selected: selected).environment(\.colorScheme, scheme))
            renderer.scale = 2
            return try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }
        let selected = try bitmap(selected: true), unselected = try bitmap(selected: false)
        #expect(selected.pixelsWide == 20 && selected.pixelsHigh == 4)
        #expect(unselected.pixelsWide == selected.pixelsWide && unselected.pixelsHigh == selected.pixelsHigh)
        #expect((selected.colorAt(x: 10, y: 1)?.alphaComponent ?? 0) > 0.99)
        #expect((unselected.colorAt(x: 10, y: 1)?.alphaComponent ?? 1) == 0)
    }
}
