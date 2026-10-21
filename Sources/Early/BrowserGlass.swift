// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// One policy for every custom glass surface. The existing transparency setting
/// also provides an immediate, app-wide way to turn the treatment off.
struct BrowserGlassPolicy: Equatable {
    var supportsLiquidGlass: Bool
    var allowsTransparency: Bool
    var reduceTransparency: Bool
    var increasedContrast: Bool
    var reduceMotion: Bool

    var usesLiquidGlass: Bool {
        supportsLiquidGlass && allowsTransparency && !reduceTransparency && !increasedContrast
    }

    var allowsInteraction: Bool { usesLiquidGlass && !reduceMotion }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }
}

/// Decorative backgrounds only: never wrap/reparent a live WKWebView or change
/// a control's layout, gesture, hit testing, or accessibility identity for glass.
/// Callers retain their original drawing on macOS 14/15 and with solid chrome.
struct BrowserGlassBackground<Fallback: View>: View {
    var cornerRadius: CGFloat
    var tint: Color? = nil
    var emphasis: Double = 0
    var interactive = false
    var allowsTransparency = true
    @ViewBuilder var fallback: () -> Fallback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let policy = BrowserGlassPolicy(supportsLiquidGlass: BrowserGlassPolicy.isSupported,
            allowsTransparency: allowsTransparency, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased, reduceMotion: reduceMotion)
        Group {
            if #available(macOS 26.0, *), policy.usesLiquidGlass {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(emphasis))
                    .glassEffect(.regular.tint(tint).interactive(interactive && policy.allowsInteraction),
                                 in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                fallback()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Batch neighboring islands without merging them across their normal gaps.
/// Keep the frame and anchored folder envelopes outside a row's glass batch:
/// their overlapping bounds must not union with a tab's selection island.
struct BrowserGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0, content: content)
        } else {
            content()
        }
    }
}

extension View {
    func browserGlassGroup() -> some View {
        BrowserGlassGroup { self }
    }
}
