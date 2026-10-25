// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Layered folder artwork shared by live rows, Space pages and drag previews.
/// What a folder shows on its front: an icon from the Space set, or GitHub's
/// mark on a GitHub live folder.
enum FolderEmblem: Equatable {
    case symbol(String), github

    init?(_ folder: BrowserFolder) {
        if folder.live?.source == .githubPullRequests { self = .github }
        else if case .symbol(let symbol)? = folder.icon { self = .symbol(symbol.rawValue) }
        else { return nil }
    }
}

struct FolderIcon: View {
    /// Room for an icon on the front.
    static let width: CGFloat = 22
    static let height: CGFloat = 24

    let isOpen: Bool
    var themeColor: BrowserSpace.Color = .gray
    var emblem: FolderEmblem?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var color: BrowserSpace.Color { contrast == .increased ? .gray : themeColor }

    private var outline: Color {
        colorScheme == .dark
            ? Color(white: 0.83)
            : Color(white: 0.38)
    }

    var body: some View {
        ZStack {
            FolderBack(openness: isOpen ? 1 : 0)
                .fill(color.folderBack(isDark: colorScheme == .dark).color)
                .overlay {
                    FolderBack(openness: isOpen ? 1 : 0)
                        .stroke(outline, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            FolderCover(openness: isOpen ? 1 : 0)
                .fill(color.folderFront(isDark: colorScheme == .dark).color)
                .overlay {
                    FolderCover(openness: isOpen ? 1 : 0)
                        .stroke(outline, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            if let emblem {
                GeometryReader { geometry in
                    let size = geometry.size
                    FolderEmblemView(emblem: emblem)
                        .foregroundStyle(outline)
                        .frame(width: size.width * 0.42, height: size.width * 0.42)
                        .position(x: size.width * 0.5, y: size.height * 0.62)
                }
                // On the front, moving with it as the folder opens.
                .modifier(FolderFrontLean(openness: isOpen ? 1 : 0))
                .accessibilityHidden(true)
            }
        }
    }
}

struct FolderEmblemView: View {
    let emblem: FolderEmblem

    var body: some View {
        switch emblem {
        case .github:
            GitHubMark().fill(style: FillStyle(eoFill: true))
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit().fontWeight(.semibold)
        }
    }
}

/// Moves a folder's icon exactly as its front moves.
struct FolderFrontLean: GeometryEffect {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(FolderLean.front.transform(openness, in: CGRect(origin: .zero, size: size)))
    }
}

/// GitHub's own mark (its logo, as GitHub's logo guidelines allow for linking
/// to GitHub), drawn as a shape rather than taken from an icon set.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * side, y: origin.y + y * side) }
        var path = Path()
        path.move(to: p(0.5, 0))
        path.addCurve(to: p(1, 0.5), control1: p(0.7762, 0), control2: p(1, 0.2238))
        path.addCurve(to: p(0.6594, 0.9744), control1: p(0.9999, 0.7148), control2: p(0.8629, 0.9057))
        path.addCurve(to: p(0.625, 0.9506), control1: p(0.6344, 0.9794), control2: p(0.625, 0.9637))
        path.addCurve(to: p(0.6256, 0.8131), control1: p(0.625, 0.9337), control2: p(0.6256, 0.88))
        path.addCurve(to: p(0.5919, 0.7206), control1: p(0.6256, 0.7662), control2: p(0.61, 0.7362))
        path.addCurve(to: p(0.82, 0.4737), control1: p(0.7031, 0.7081), control2: p(0.82, 0.6656))
        path.addCurve(to: p(0.7687, 0.3394), control1: p(0.82, 0.4187), control2: p(0.8006, 0.3744))
        path.addCurve(to: p(0.7637, 0.2069), control1: p(0.7737, 0.3269), control2: p(0.7912, 0.2756))
        path.addCurve(to: p(0.6262, 0.2581), control1: p(0.7637, 0.2069), control2: p(0.7219, 0.1931))
        path.addCurve(to: p(0.5012, 0.2412), control1: p(0.5862, 0.2469), control2: p(0.5437, 0.2412))
        path.addCurve(to: p(0.3762, 0.2581), control1: p(0.4587, 0.2412), control2: p(0.4162, 0.2469))
        path.addCurve(to: p(0.2387, 0.2069), control1: p(0.2806, 0.1937), control2: p(0.2387, 0.2069))
        path.addCurve(to: p(0.2337, 0.3394), control1: p(0.2112, 0.2756), control2: p(0.2287, 0.3269))
        path.addCurve(to: p(0.1825, 0.4737), control1: p(0.2019, 0.3744), control2: p(0.1825, 0.4194))
        path.addCurve(to: p(0.41, 0.7206), control1: p(0.1825, 0.665), control2: p(0.2987, 0.7081))
        path.addCurve(to: p(0.3781, 0.7875), control1: p(0.3956, 0.7331), control2: p(0.3825, 0.755))
        path.addCurve(to: p(0.2325, 0.7462), control1: p(0.3494, 0.8006), control2: p(0.2775, 0.8219))
        path.addCurve(to: p(0.1556, 0.695), control1: p(0.2231, 0.7312), control2: p(0.195, 0.6944))
        path.addCurve(to: p(0.1562, 0.7281), control1: p(0.1137, 0.6956), control2: p(0.1387, 0.7187))
        path.addCurve(to: p(0.2075, 0.7987), control1: p(0.1775, 0.74), control2: p(0.2019, 0.7844))
        path.addCurve(to: p(0.3756, 0.8575), control1: p(0.2175, 0.8269), control2: p(0.25, 0.8806))
        path.addCurve(to: p(0.3762, 0.9506), control1: p(0.3756, 0.8994), control2: p(0.3762, 0.9387))
        path.addCurve(to: p(0.3419, 0.9744), control1: p(0.3762, 0.9637), control2: p(0.3669, 0.9787))
        path.addCurve(to: p(-0, 0.5), control1: p(0.1376, 0.9064), control2: p(-0.0001, 0.7153))
        path.addCurve(to: p(0.5, 0), control1: p(0, 0.2238), control2: p(0.2238, 0))
        path.closeSubpath()
        return path
    }
}

/// How a folder's half moves as it opens: hinged on the bottom edge, its top
/// leans one way (`shear`) and comes forward or goes back (`squash`).
struct FolderLean {
    static let hinge: CGFloat = 0.88
    static let back = FolderLean(shear: -0.16, squash: 0.04)
    static let front = FolderLean(shear: 0.24, squash: 0.14)

    let shear: CGFloat
    let squash: CGFloat

    /// From closed (0) to open (1), in a rect's own coordinates.
    func transform(_ openness: CGFloat, in rect: CGRect) -> CGAffineTransform {
        let narrow = 1 - 0.08 * openness, lean = shear * openness, height = 1 - squash * openness
        // In the unit square: x' = 0.5 + (x − 0.5)·narrow + lean·(hinge − y), y' = hinge − (hinge − y)·height.
        let unitX = 0.5 - 0.5 * narrow + Self.hinge * lean, unitY = Self.hinge * (1 - height)
        let ratio = rect.height > 0 ? rect.width / rect.height : 1
        return CGAffineTransform(a: narrow, b: 0, c: -lean * ratio, d: height,
                                 tx: rect.minX + rect.width * unitX - narrow * rect.minX + lean * ratio * rect.minY,
                                 ty: rect.minY + rect.height * unitY - height * rect.minY)
    }
}

/// The back and its tab; opening tips it back.
struct FolderBack: Shape {
    var openness: CGFloat = 0
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.18, 0.88))
        path.addQuadCurve(to: point(0.06, 0.76), control: point(0.06, 0.88))
        path.addLine(to: point(0.06, 0.28))
        path.addQuadCurve(to: point(0.16, 0.18), control: point(0.06, 0.18))
        path.addLine(to: point(0.33, 0.18))
        path.addQuadCurve(to: point(0.40, 0.21), control: point(0.37, 0.18))
        path.addLine(to: point(0.46, 0.27))
        path.addQuadCurve(to: point(0.53, 0.30), control: point(0.49, 0.30))
        path.addLine(to: point(0.76, 0.30))
        path.addQuadCurve(to: point(0.88, 0.41), control: point(0.88, 0.30))
        path.addLine(to: point(0.88, 0.76))
        path.addQuadCurve(to: point(0.76, 0.88), control: point(0.88, 0.88))
        path.closeSubpath()
        return path.applying(FolderLean.back.transform(openness, in: rect))
    }
}

/// The front; opening tips it toward you.
struct FolderCover: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.18, 0.88))
        path.addQuadCurve(to: point(0.06, 0.76), control: point(0.06, 0.88))
        path.addLine(to: point(0.06, 0.48))
        path.addQuadCurve(to: point(0.18, 0.36), control: point(0.06, 0.36))
        path.addLine(to: point(0.82, 0.36))
        path.addQuadCurve(to: point(0.94, 0.48), control: point(0.94, 0.36))
        path.addLine(to: point(0.94, 0.76))
        path.addQuadCurve(to: point(0.82, 0.88), control: point(0.94, 0.88))
        path.closeSubpath()
        return path.applying(FolderLean.front.transform(openness, in: rect))
    }
}
