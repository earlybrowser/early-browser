// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

private struct BrowserTransparencyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var browserAllowsTransparency: Bool {
        get { self[BrowserTransparencyKey.self] }
        set { self[BrowserTransparencyKey.self] = newValue }
    }
}

enum BrowserGlassRole: CaseIterable {
    case chrome, island, floating, control
}

/// Final contrast treatment, not a glass tint. Native refraction can lift a dark
/// surface or wash out a light selection, so these colors draw above the effect
/// and below foreground content. The values remain local to the surface.
enum BrowserSurfacePalette {
    static func darkeningOpacity(isDark: Bool, role: BrowserGlassRole) -> Double {
        if !isDark { return role == .chrome ? 0 : 0.025 }
        switch role {
        case .chrome: return 0.62
        case .island, .floating: return 0.58
        case .control: return 0.48
        }
    }

    static func fillOpacity(_ requested: Double, isDark: Bool) -> Double {
        guard requested > 0 else { return 0 }
        return isDark ? min(1, requested) : min(0.30, requested * 1.5 + 0.012)
    }

    static func borderOpacity(isDark: Bool) -> Double { isDark ? 0.07 : 0.14 }
}

struct BrowserGlassPolicy: Equatable {
    var supportsLiquidGlass: Bool
    var allowsTransparency: Bool
    var reduceTransparency: Bool
    var increasedContrast: Bool

    var usesGlass: Bool {
        supportsLiquidGlass && allowsTransparency && !reduceTransparency && !increasedContrast
    }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }
}

/// An untinted decorative layer over an existing, legible base. Foreground
/// artwork stays outside it. No shared glass container, filters or deformation.
struct BrowserGlassBackground: View {
    // Restrict native glass to convex rounded surfaces. Page cutouts belong to
    // a later mask, so the narrow concave inner edge is never refracted.
    var shape: RoundedRectangle
    var allowsTransparency: Bool
    var role: BrowserGlassRole = .island
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let policy = BrowserGlassPolicy(supportsLiquidGlass: BrowserGlassPolicy.isSupported,
            allowsTransparency: allowsTransparency, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased)
        Group {
            if #available(macOS 26.0, *), policy.usesGlass {
                shape.fill(.clear)
                    .glassEffect(.clear.interactive(false), in: shape)
                    .overlay {
                        shape.fill(Color.black.opacity(BrowserSurfacePalette.darkeningOpacity(
                            isDark: colorScheme == .dark, role: role)))
                    }
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BrowserIslandBackground: View {
    var cornerRadius: CGFloat
    var fillOpacity: Double
    var color: Color? = nil
    var colorOpacity: Double = 0
    var allowsTransparency: Bool
    var role: BrowserGlassRole = .island
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(.clear)
        .overlay { BrowserGlassBackground(shape: shape, allowsTransparency: allowsTransparency, role: role) }
        .overlay {
            shape.fill(Color.primary.opacity(BrowserSurfacePalette.fillOpacity(fillOpacity, isDark: colorScheme == .dark)))
        }
        .overlay { if let color { shape.fill(color.opacity(colorOpacity)) } }
        .overlay {
            if role != .control {
                shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.40
                    : BrowserSurfacePalette.borderOpacity(isDark: colorScheme == .dark)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Alpha mask only, never the native glass's refracting shape. Reflection
/// reverses the inner contour's winding without changing its rounded bounds.
struct BrowserChromeGlassShape: Shape {
    var contentLeadingInset: CGFloat
    var windowCornerRadius: CGFloat
    static let margin: CGFloat = 6

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(contentLeadingInset, windowCornerRadius) }
        set {
            contentLeadingInset = newValue.first
            windowCornerRadius = newValue.second
        }
    }

    func contentRect(in rect: CGRect) -> CGRect {
        let leading = min(max(Self.margin, contentLeadingInset), max(Self.margin, rect.width - Self.margin))
        return CGRect(x: rect.minX + leading, y: rect.minY + Self.margin,
            width: max(0, rect.width - leading - Self.margin), height: max(0, rect.height - 2 * Self.margin))
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        var path = RoundedRectangle(cornerRadius: windowCornerRadius).path(in: rect)
        let content = contentRect(in: rect)
        if content.width > 0, content.height > 0 {
            let inner = RoundedRectangle(cornerRadius: max(windowCornerRadius - Self.margin, 4)).path(in: content)
            path.addPath(inner, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                tx: 2 * content.midX, ty: 0))
        }
        return path
    }
}

struct BrowserFrameGlassBackground: View {
    var contentLeadingInset: CGFloat
    var windowCornerRadius: CGFloat
    var allowsTransparency: Bool

    var maskShape: BrowserChromeGlassShape {
        BrowserChromeGlassShape(contentLeadingInset: contentLeadingInset, windowCornerRadius: windowCornerRadius)
    }

    var body: some View {
        BrowserGlassBackground(shape: RoundedRectangle(cornerRadius: windowCornerRadius),
            allowsTransparency: allowsTransparency, role: .chrome)
            .compositingGroup()
            .mask { maskShape.fill(.white) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Floating cards keep their previous themed/material base underneath the same
/// clear effect as the islands; the effect itself never receives a color tint.
struct BrowserFloatingBackground: View {
    var spaceColor: BrowserSpace.Color?
    var cornerRadius: CGFloat
    var allowsTransparency: Bool
    var color: Color? = nil
    var colorOpacity: Double = 0
    var role: BrowserGlassRole = .floating
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        Group {
            if let spaceColor, contrast != .increased {
                BrowserChromeBackground(spaceColor: spaceColor, floating: true,
                    allowsTransparency: allowsTransparency)
            } else if reduceTransparency || !allowsTransparency || contrast == .increased {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.thickMaterial)
            }
        }
        .clipShape(shape)
        .overlay { BrowserGlassBackground(shape: shape, allowsTransparency: allowsTransparency, role: role) }
        .overlay { if let color { shape.fill(color.opacity(colorOpacity)) } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BrowserControlBackground: View {
    var highlighted: Bool
    var cornerRadius: CGFloat = 6
    @Environment(\.browserAllowsTransparency) private var allowsTransparency

    var body: some View {
        if highlighted {
            BrowserIslandBackground(cornerRadius: cornerRadius, fillOpacity: 0.12,
                allowsTransparency: allowsTransparency, role: .control)
        }
    }
}

private struct BrowserEditorPanel: ViewModifier {
    @Environment(\.browserAllowsTransparency) private var allowsTransparency

    func body(content: Content) -> some View {
        // Keep the native sheet host/focus/alerts. macOS sheets are opaque;
        // style their presentation surface without pretending to see through it.
        content.presentationBackground {
            BrowserFloatingBackground(spaceColor: nil, cornerRadius: 0,
                allowsTransparency: allowsTransparency)
        }
    }
}

extension View {
    func browserEditorPanel() -> some View { modifier(BrowserEditorPanel()) }
}

struct BrowserToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Appearance(configuration: configuration) }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    BrowserControlBackground(highlighted: isEnabled && (hovered || configuration.isPressed), cornerRadius: 8)
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hovered = $0 }
        }
    }
}

enum FavoriteCardPalette {
    static func saturation(for saturation: CGFloat) -> CGFloat { min(max(0, saturation) * 0.85, 0.78) }
    static func brightness(isDark: Bool) -> Double { isDark ? 0.78 : 0.70 }
    static func fillOpacity(isDark: Bool) -> Double { isDark ? 0.40 : 0.32 }
}

struct FavoriteCardBackground: View {
    var selected: Bool
    var hovered: Bool
    var tint: Color?
    var allowsTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        BrowserIslandBackground(cornerRadius: 9, fillOpacity: selected ? 0.12 : (hovered ? 0.08 : 0.04),
            color: selected ? tint : nil, colorOpacity: FavoriteCardPalette.fillOpacity(isDark: colorScheme == .dark),
            allowsTransparency: allowsTransparency)
    }
}
