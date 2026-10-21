// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

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
struct BrowserGlassBackground<Surface: Shape>: View {
    var shape: Surface
    var allowsTransparency: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let policy = BrowserGlassPolicy(supportsLiquidGlass: BrowserGlassPolicy.isSupported,
            allowsTransparency: allowsTransparency, reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased)
        Group {
            if #available(macOS 26.0, *), policy.usesGlass {
                shape.fill(.clear).glassEffect(.clear.interactive(false), in: shape)
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape.fill(Color.primary.opacity(fillOpacity))
            if let color { shape.fill(color.opacity(colorOpacity)) }
        }
        .overlay { BrowserGlassBackground(shape: shape, allowsTransparency: allowsTransparency) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One connected sidebar/rim with a genuine hole for the page. Reflection
/// reverses the inner contour's winding without changing its rounded bounds.
/// The same path clips the effect, so glass cannot spread onto the page canvas.
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

/// Floating cards keep their previous themed/material base underneath the same
/// clear effect as the islands; the effect itself never receives a color tint.
struct BrowserFloatingBackground: View {
    var spaceColor: BrowserSpace.Color?
    var cornerRadius: CGFloat
    var allowsTransparency: Bool
    var color: Color? = nil
    var colorOpacity: Double = 0
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
        .overlay { if let color { shape.fill(color.opacity(colorOpacity)) } }
        .overlay { BrowserGlassBackground(shape: shape, allowsTransparency: allowsTransparency) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
