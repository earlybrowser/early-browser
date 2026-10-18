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
        return swatch.blended(with: neutral, amount: isDark ? 0.065 : 0.34)
    }

    func chromeBottom(isDark: Bool) -> SpaceThemeRGB {
        let neutral = isDark ? SpaceThemeRGB(red: 0.010, green: 0.010, blue: 0.010)
            : SpaceThemeRGB(red: 0.975, green: 0.947, blue: 0.88)
        return swatch.blended(with: neutral, amount: isDark ? 0.04 : 0.25)
    }
}
