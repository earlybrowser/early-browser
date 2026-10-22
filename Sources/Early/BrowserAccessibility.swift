// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

/// A neutral, opaque cue: keyboard focus must not depend on the Space hue or
/// a translucent selection fill. Draw inward without changing control geometry.
struct BrowserFocusOutline: View {
    let focused: Bool
    var cornerRadius: CGFloat = 7
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Stroke(focused: focused, cornerRadius: cornerRadius, increasedContrast: contrast == .increased)
    }

    struct Stroke: View {
        let focused: Bool
        let cornerRadius: CGFloat
        let increasedContrast: Bool
        @Environment(\.colorScheme) private var colorScheme
        var body: some View {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder((colorScheme == .dark ? Color.white : .black).opacity(focused ? 1 : 0),
                              lineWidth: increasedContrast ? 3 : 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BrowserKeyboardFocus: ViewModifier {
    let cornerRadius: CGFloat
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled()
            .overlay { BrowserFocusOutline(focused: focused, cornerRadius: cornerRadius) }
    }
}

/// An outer transaction boundary also covers inherited animations and implicit
/// transitions, not just individual `.animation` calls. Never change OS settings.
enum BrowserMotionPolicy {
    static func apply(to transaction: inout Transaction, reduceMotion: Bool) {
        guard reduceMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private struct BrowserReducedMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transaction { BrowserMotionPolicy.apply(to: &$0, reduceMotion: reduceMotion) }
    }
}

extension View {
    /// Bind native Button focus; do not add a second focusable wrapper or
    /// override the user's macOS keyboard-navigation preference.
    func browserKeyboardFocus(cornerRadius: CGFloat = 7) -> some View {
        modifier(BrowserKeyboardFocus(cornerRadius: cornerRadius))
    }

    func browserReducedMotion() -> some View { modifier(BrowserReducedMotion()) }
}

enum SidebarKeyboardResize {
    static func delta(for key: KeyEquivalent, modifiers: EventModifiers) -> Double? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        return key == .leftArrow ? -16 : (key == .rightArrow ? 16 : nil)
    }
}

/// A non-color cue for the selected Space icon picker choice.
struct BrowserSelectionMark: View {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Capsule().fill(colorScheme == .dark ? Color.white : .black).frame(width: 10, height: 2)
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Picker swatches are fixed sRGB colors, independent of appearance. Choose
/// the stronger black/white checkmark instead of washing out yellow/orange.
enum BrowserChoiceContrast {
    static func luminance(of rgb: SpaceThemeRGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    static func usesDarkMark(on rgb: SpaceThemeRGB) -> Bool {
        let luminance = luminance(of: rgb)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }
}

extension BrowserSpace.Color {
    var accessibleCheckmark: Color { BrowserChoiceContrast.usesDarkMark(on: swatch) ? .black : .white }
}

enum BrowserTabAccessibility {
    struct Action: Identifiable {
        let title: String
        let action: BrowserAction
        var id: String { title }
    }

    static func value(for tab: BrowserTab, isLoading: Bool = false, hasFailure: Bool = false,
                      isMuted: Bool = false, isPlayingMedia: Bool = false) -> String {
        let section = tab.isFavorite ? "Favorite" : "Pinned"
        let base = tab.pinnedURL == nil ? "Today" : "\(section), \(tab.isOpen ? "open" : "closed")"
        guard tab.isOpen else { return base }
        let media = isMuted ? ", muted" : (isPlayingMedia ? ", media playing" : "")
        if isLoading { return base + media + ", loading" }
        if hasFailure { return base + media + ", load failed" }
        return base + media
    }

    /// These supplement the default Select/Reopen action. Actual availability
    /// and execution still go through the same dispatcher as native menus.
    static func actions(for tab: BrowserTab, isMuted: Bool, hasMedia: Bool) -> [Action] {
        var actions = [Action(title: "Rename Tab", action: .requestRename(tab.id))]
        if tab.isOpen { actions.append(Action(title: "Close Tab", action: .closeTab(tab.id))) }
        if tab.hasNavigatedFromPin {
            actions.append(Action(title: "Reset to Pinned URL", action: .resetPinnedTab(tab.id)))
        }
        if tab.isOpen && hasMedia {
            actions.append(Action(title: isMuted ? "Unmute Tab" : "Mute Tab", action: .setMuted(tab.id, !isMuted)))
        }
        actions += [Action(title: "Move Up", action: .moveTabBy(tab.id, -1)),
                    Action(title: "Move Down", action: .moveTabBy(tab.id, 1))]
        return actions
    }

    @MainActor static func availableActions(for tab: BrowserTab, in model: BrowserWindowModel) -> [Action] {
        let page = model.webViews.pages[tab.id]
        return actions(for: tab, isMuted: page?.isMuted == true,
            hasMedia: page?.isPlayingMedia == true || page?.isMuted == true)
            .filter { model.canPerform($0.action) }
    }
}

struct BrowserTabAccessibilityActions: ViewModifier {
    let model: BrowserWindowModel
    let tab: BrowserTab

    func body(content: Content) -> some View {
        let actions = BrowserTabAccessibility.availableActions(for: tab, in: model)
        content.accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { _ = model.perform(action.action) }
            }
        }
    }
}
