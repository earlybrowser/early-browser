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
        #expect(SidebarKeyboardResize.delta(forKeyCode: 123, modifiers: [.function, .numericPad]) == -16)
        #expect(SidebarKeyboardResize.delta(forKeyCode: 124, modifiers: .shift) == 16)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.control, .option], [.command, .shift]] {
            #expect(SidebarKeyboardResize.delta(forKeyCode: 123, modifiers: modifiers) == nil)
            #expect(SidebarKeyboardResize.delta(forKeyCode: 124, modifiers: modifiers) == nil)
        }
        for keyCode: UInt16 in [48, 53, 49, 17] { // Tab, Escape, Space, T
            #expect(SidebarKeyboardResize.delta(forKeyCode: keyCode, modifiers: []) == nil)
        }
        #expect(SidebarWidth.clamped(SidebarWidth.minimum - 16) == SidebarWidth.minimum)
        #expect(SidebarWidth.clamped(SidebarWidth.maximum + 16) == SidebarWidth.maximum)
    }

    @Test func sidebarEdgeIsOneNativeSplitterThatPointerPressesCannotFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let edge = SidebarResizeEdge.EdgeView(frame: CGRect(x: 237, y: 0, width: 12, height: 600))
        try #require(window.contentView).addSubview(edge)
        defer { edge.invalidate(); window.close() }
        edge.configure(width: 240, increasedContrast: false)
        var adjustments: [Double] = [], travel: [Double] = [], phases: [String] = []
        edge.onAdjust = { adjustments.append($0) }
        edge.onBegin = { phases.append("begin") }
        edge.onResize = { travel.append($0) }
        edge.onEnd = { phases.append("end") }

        // One native element replaces the SwiftUI focusable view, which exposed two.
        #expect(edge.isAccessibilityElement() && edge.accessibilityRole() == .splitter)
        #expect(edge.accessibilityIdentifier() == "sidebar.resize" && edge.accessibilityLabel() == "Sidebar width")
        #expect(edge.accessibilityValue() as? String == "240 points")
        #expect(edge.accessibilityPerformIncrement() && edge.accessibilityPerformDecrement())
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F702}",
            charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        edge.keyDown(with: arrow)
        #expect(adjustments == [16, -16, -16])

        // A click or drag keeps the page's keyboard focus; keyboard navigation may focus it.
        for press: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(!SidebarResizeEdge.EdgeView.acceptsFocus(during: press))
        }
        #expect(SidebarResizeEdge.EdgeView.acceptsFocus(during: .keyDown))
        #expect(SidebarResizeEdge.EdgeView.acceptsFocus(during: nil))
        #expect(edge.focusRingType == .none && edge.becomeFirstResponder() && edge.keyboardFocused)
        #expect(edge.resignFirstResponder() && !edge.keyboardFocused)

        edge.resetCursorRects()
        let cursor = try #require(edge.resizeCursorRect)
        #expect(abs(cursor.width - 12) < 0.001, "Native resize cursor covers the whole grab area: \(cursor)")
        edge.beginResize(atWindowX: 243)
        edge.updateResize(atWindowX: 283)
        edge.endResize()
        #expect(phases == ["begin", "end"] && travel == [40])

        edge.beginResize(atWindowX: 243)
        edge.invalidate()
        #expect(phases == ["begin", "end", "begin", "end"], "Teardown ends an unfinished drag")
        #expect(!edge.accessibilityPerformIncrement() && edge.resizeCursorRect == nil && !window.isVisible)
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
    func theSelectedSpaceDotHasAShapeCueWhenColorAloneIsntEnough(_ scheme: ColorScheme) throws {
        func bitmap(selected: Bool, differentiate: Bool = true) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: SpaceDotLabel(icon: nil, selected: selected, opacity: 1, marksSelection: differentiate)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            return try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }
        let selected = try bitmap(selected: true), unselected = try bitmap(selected: false)
        #expect(selected.pixelsWide == unselected.pixelsWide && selected.pixelsHigh == 56)
        let x = selected.pixelsWide / 2, y = selected.pixelsHigh - 8
        let mark = try #require(selected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        #expect(mark.alphaComponent > 0.99)
        #expect((unselected.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0)
        #expect(scheme == .dark ? mark.redComponent > 0.8 : mark.redComponent < 0.2)
        // Otherwise the brighter icon alone shows the selection.
        let plain = try bitmap(selected: true, differentiate: false)
        #expect(plain.pixelsHigh == selected.pixelsHigh && (plain.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectedIconChoiceHasANonColorCueWithStableDimensions(_ scheme: ColorScheme) throws {
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
