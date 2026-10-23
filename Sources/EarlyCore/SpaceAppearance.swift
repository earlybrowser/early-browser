// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A Space's optional identity is independent of its chrome theme color.
public enum SpaceIcon: Codable, Equatable, Sendable {
    case symbol(Symbol)

    public enum Symbol: String, Codable, CaseIterable, Sendable {
        case star = "star.fill", bookmark = "bookmark.fill", heart = "heart.fill", flag = "flag.fill"
        case bolt = "bolt.fill", triangle = "triangle.fill", sparkle = "sparkle", bell = "bell.fill"
        case lightbulb = "lightbulb.fill", flame = "flame.fill", grid = "square.grid.2x2.fill", dots = "circle.grid.3x3.fill"
        case layers = "square.3.layers.3d", database = "externaldrive.fill", archive = "archivebox.fill", windows = "square.on.square.fill"
        case folder = "folder.fill", briefcase = "briefcase.fill", calendar = "calendar", envelope = "envelope.fill"
        case checkmark = "checkmark.square.fill", document = "doc.fill", book = "book.fill", chat = "ellipsis.message.fill"
        case people = "person.2.fill", terminal = "terminal.fill", tools = "wrench.and.screwdriver.fill", square = "square.fill"
        case leaf = "leaf.fill", circle = "circle.fill", moon = "moon.fill", sun = "sun.max.fill"
        case globe = "globe.americas.fill", leafOutline = "leaf", cloud = "cloud.fill", paw = "pawprint.fill"
        case basket = "basket.fill", gift = "gift.fill", bed = "bed.double.fill", food = "fork.knife"
        case fitness = "dumbbell.fill", airplane = "airplane", music = "music.note", palette = "paintpalette.fill"
        case video = "video.fill", bandage = "bandage.fill", code = "chevron.left.forwardslash.chevron.right", ball = "soccerball"
        case cloudOutline = "cloud", map = "map.fill", bug = "ladybug.fill", game = "gamecontroller.fill"
        case masks = "theatermasks.fill", newspaper = "newspaper.fill", thumbsUp = "hand.thumbsup.fill", train = "tram.fill"

        public var label: String {
            switch self {
            case .lightbulb: "Light bulb"
            case .dots: "Dot grid"
            case .thumbsUp: "Thumbs up"
            case .masks: "Theater masks"
            case .leafOutline: "Leaf outline"
            case .cloudOutline: "Cloud outline"
            default: String(describing: self).capitalized
            }
        }
    }
}

/// Fixed sRGB values keep picker swatches identical in both appearances. Only
/// the applied chrome palette blends those colors toward dark or light neutrals.
public struct SpaceThemeRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    fileprivate func blended(with neutral: Self, amount: Double) -> Self {
        Self(red: neutral.red + (red - neutral.red) * amount,
             green: neutral.green + (green - neutral.green) * amount,
             blue: neutral.blue + (blue - neutral.blue) * amount)
    }
}

public extension BrowserSpace.Color {
    var swatch: SpaceThemeRGB {
        switch self {
        case .gray: SpaceThemeRGB(red: 0.54, green: 0.55, blue: 0.58)
        case .blue: SpaceThemeRGB(red: 0.23, green: 0.49, blue: 0.88)
        case .purple: SpaceThemeRGB(red: 0.62, green: 0.41, blue: 0.82)
        case .pink: SpaceThemeRGB(red: 0.87, green: 0.42, blue: 0.64)
        case .red: SpaceThemeRGB(red: 0.87, green: 0.34, blue: 0.34)
        case .orange: SpaceThemeRGB(red: 0.91, green: 0.55, blue: 0.25)
        case .yellow: SpaceThemeRGB(red: 0.89, green: 0.73, blue: 0.28)
        case .green: SpaceThemeRGB(red: 0.34, green: 0.67, blue: 0.46)
        }
    }

    func chromeTop(isDark: Bool) -> SpaceThemeRGB {
        let neutral = isDark ? SpaceThemeRGB(red: 0.018, green: 0.018, blue: 0.018)
            : SpaceThemeRGB(red: 0.99, green: 0.965, blue: 0.91)
        return swatch.blended(with: neutral, amount: isDark ? 0.14 : 0.34)
    }

    func chromeBottom(isDark: Bool) -> SpaceThemeRGB {
        let neutral = isDark ? SpaceThemeRGB(red: 0.010, green: 0.010, blue: 0.010)
            : SpaceThemeRGB(red: 0.975, green: 0.947, blue: 0.88)
        return swatch.blended(with: neutral, amount: isDark ? 0.09 : 0.25)
    }

    /// A muted, legible focus edge, not a translucent copy of the swatch.
    /// Darken warm/light hues against light pages and lift them against dark
    /// pages. Gray is also the neutral fallback when Space themes are disabled.
    func focusBorder(isDark: Bool, increasedContrast: Bool = false) -> SpaceThemeRGB {
        let gray: Double
        if self == .gray {
            gray = increasedContrast ? (isDark ? 0.82 : 0.18) : (isDark ? 0.62 : 0.43)
            return SpaceThemeRGB(red: gray, green: gray, blue: gray)
        }
        gray = increasedContrast ? (isDark ? 0.88 : 0.04) : (isDark ? 0.55 : 0.18)
        return swatch.blended(with: SpaceThemeRGB(red: gray, green: gray, blue: gray),
                              amount: increasedContrast ? 0.45 : 0.55)
    }

    /// Muted layers keep folder artwork at home in its Space without tinting
    /// text or reducing the contrast of the icon's outline. Gray also preserves
    /// the original neutral artwork when Space themes are disabled.
    /// Folders are flat and filled: a deeper back and tab behind a lighter
    /// front, in both appearances.
    func folderBack(isDark: Bool) -> SpaceThemeRGB {
        if self == .gray {
            let gray = isDark ? 0.36 : 0.58
            return SpaceThemeRGB(red: gray, green: gray, blue: gray)
        }
        return swatch.blended(with: SpaceThemeRGB(red: 0.06, green: 0.06, blue: 0.07), amount: isDark ? 0.56 : 0.74)
    }

    func folderFront(isDark: Bool) -> SpaceThemeRGB {
        if self == .gray {
            let gray = isDark ? 0.6 : 0.8
            return SpaceThemeRGB(red: gray, green: gray, blue: gray)
        }
        return isDark ? swatch.blended(with: SpaceThemeRGB(red: 0.12, green: 0.12, blue: 0.13), amount: 0.86)
            : swatch.blended(with: SpaceThemeRGB(red: 1, green: 1, blue: 1), amount: 0.86)
    }
}

/// The palette a window's chrome is drawn with: its Space's color, or the
/// private-window gray that no Space or profile can choose.
public enum WindowTheme: Hashable, Sendable {
    case space(BrowserSpace.Color)
    case privateBrowsing

    /// A cool dark gray, lighter than the gray Space's dark chrome. It is the
    /// same in both appearances, so private windows always draw their chrome
    /// dark, with white text; pages keep Early's own appearance.
    private static let privateTop = SpaceThemeRGB(red: 0.227, green: 0.227, blue: 0.251)
    private static let privateBottom = SpaceThemeRGB(red: 0.180, green: 0.180, blue: 0.200)

    public var swatch: SpaceThemeRGB {
        switch self {
        case .space(let color): color.swatch
        case .privateBrowsing: SpaceThemeRGB(red: 0.60, green: 0.60, blue: 0.64)
        }
    }

    public func chromeTop(isDark: Bool) -> SpaceThemeRGB {
        switch self {
        case .space(let color): color.chromeTop(isDark: isDark)
        case .privateBrowsing: Self.privateTop
        }
    }

    public func chromeBottom(isDark: Bool) -> SpaceThemeRGB {
        switch self {
        case .space(let color): color.chromeBottom(isDark: isDark)
        case .privateBrowsing: Self.privateBottom
        }
    }

    /// Private windows keep one silver edge against their dark gray chrome.
    public func focusBorder(isDark: Bool, increasedContrast: Bool = false) -> SpaceThemeRGB {
        switch self {
        case .space(let color): return color.focusBorder(isDark: isDark, increasedContrast: increasedContrast)
        case .privateBrowsing:
            return increasedContrast ? SpaceThemeRGB(red: 0.831, green: 0.831, blue: 0.855)
                : SpaceThemeRGB(red: 0.651, green: 0.651, blue: 0.682)
        }
    }
}
