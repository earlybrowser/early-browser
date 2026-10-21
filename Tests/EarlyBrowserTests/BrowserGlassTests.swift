// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import SwiftUI
import Testing

@Suite(.serialized) @MainActor
struct BrowserGlassTests {
    @Test func glassRequiresEveryAvailabilityAndAccessibilityGate() {
        for supported in [false, true] {
            for translucent in [false, true] {
                for reduced in [false, true] {
                    for increased in [false, true] {
                        let policy = BrowserGlassPolicy(supportsLiquidGlass: supported, allowsTransparency: translucent,
                            reduceTransparency: reduced, increasedContrast: increased)
                        #expect(policy.usesGlass == (supported && translucent && !reduced && !increased))
                    }
                }
            }
        }
    }

    @Test func backgroundPreservesFavoriteDimensionsInBothAppearances() {
        _ = NSApplication.shared
        for width in [48.0, 72, 140, 280] {
            for translucent in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let foreground = Text("E").frame(width: width, height: 43.2)
                    let plain = NSHostingView(rootView: foreground.environment(\.colorScheme, scheme))
                    let host = NSHostingView(rootView: foreground.background {
                        FavoriteCardBackground(selected: true, hovered: false,
                            tint: .blue, allowsTransparency: translucent)
                    }.environment(\.colorScheme, scheme))
                    // Compare identical foregrounds, including AppKit's
                    // ordinary backing-pixel rounding of 43.2-point cards.
                    #expect(host.fittingSize == plain.fittingSize)
                    #expect(host.window == nil)
                }
            }
        }
    }

    /// Offscreen pixel check only, not on-screen backdrop qualification. A
    /// sharply divided opaque artwork fixture must remain a foreground layer.
    @Test func foregroundArtworkIsUnchangedByGlass() throws {
        _ = NSApplication.shared
        let artwork = HStack(spacing: 0) {
            Rectangle().fill(Color.red)
            Rectangle().fill(Color.white)
            Rectangle().fill(Color.blue)
        }.frame(width: 18, height: 18).frame(width: 72, height: 44)
        for scheme in [ColorScheme.light, .dark] {
            let reference = ImageRenderer(content: artwork.environment(\.colorScheme, scheme))
            let original = try iconPixels(in: #require(reference.cgImage))
            for translucent in [false, true] {
                let renderer = ImageRenderer(content: artwork.background {
                    FavoriteCardBackground(selected: true, hovered: true,
                        tint: .green, allowsTransparency: translucent)
                }.environment(\.colorScheme, scheme))
                #expect(try iconPixels(in: #require(renderer.cgImage)) == original)
                let framed = ImageRenderer(content: artwork.background {
                    BrowserFrameGlassBackground(contentLeadingInset: 42, windowCornerRadius: 12,
                        allowsTransparency: translucent)
                }.environment(\.colorScheme, scheme))
                #expect(try iconPixels(in: #require(framed.cgImage)) == original)
                let panel = ImageRenderer(content: artwork.background {
                    BrowserFloatingBackground(spaceColor: nil, cornerRadius: 12, allowsTransparency: translucent)
                }.environment(\.colorScheme, scheme))
                #expect(try iconPixels(in: #require(panel.cgImage)) == original)
                let control = ImageRenderer(content: artwork.background {
                    BrowserControlBackground(highlighted: true)
                }.environment(\.browserAllowsTransparency, translucent).environment(\.colorScheme, scheme))
                #expect(try iconPixels(in: #require(control.cgImage)) == original)
            }
        }
    }

    @Test func chromeIsOneSidebarAndRimWithNoGlassInsideThePage() {
        let shape = BrowserChromeGlassShape(contentLeadingInset: 252, windowCornerRadius: 16)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let path = shape.path(in: bounds)
        #expect(shape.contentRect(in: bounds) == CGRect(x: 252, y: 6, width: 942, height: 788))
        for point in [CGPoint(x: 120, y: 400), CGPoint(x: 600, y: 3),
                      CGPoint(x: 1197, y: 400), CGPoint(x: 600, y: 797)] {
            #expect(path.contains(point))
        }
        #expect(!path.contains(CGPoint(x: -1, y: 400)))
        #expect(!path.contains(CGPoint(x: 1, y: 1)))
        for x in stride(from: 270, through: 1180, by: 35) {
            for y in stride(from: 20, through: 780, by: 35) {
                #expect(!path.contains(CGPoint(x: x, y: y)))
            }
        }
    }

    @Test func chromeCutoutTracksAutoHideResizeAndConcentricCorners() {
        for width in [420.0, 840, 1800] {
            for inset in [6.0, 202, 332] {
                let shape = BrowserChromeGlassShape(contentLeadingInset: inset, windowCornerRadius: 20)
                let bounds = CGRect(x: 20, y: 30, width: width, height: 700)
                let path = shape.path(in: bounds), page = shape.contentRect(in: bounds)
                #expect(!path.contains(CGPoint(x: page.midX, y: page.midY)))
                #expect(path.contains(CGPoint(x: bounds.maxX - 3, y: bounds.midY)))
                #expect(path.contains(CGPoint(x: page.minX + 1, y: page.minY + 1)))
                #expect(!path.contains(CGPoint(x: page.minX + 14, y: page.minY + 14)))
            }
        }
        var shape = BrowserChromeGlassShape(contentLeadingInset: 252, windowCornerRadius: 16)
        shape.animatableData = AnimatablePair(6, 20)
        #expect(shape.contentLeadingInset == 6 && shape.windowCornerRadius == 20)
        #expect(shape.path(in: .zero).isEmpty)
        #expect(shape.contentRect(in: CGRect(x: 0, y: 0, width: 10, height: 10)).width == 0)
    }

    @Test func selectedFavoriteColorsAreStrongerButBounded() {
        #expect(FavoriteCardPalette.saturation(for: 0.5) > 0.5 * 0.55)
        #expect(FavoriteCardPalette.saturation(for: 0) == 0)
        #expect(FavoriteCardPalette.saturation(for: 1) <= 0.78)
        #expect(FavoriteCardPalette.fillOpacity(isDark: true) > 0.26)
        #expect(FavoriteCardPalette.fillOpacity(isDark: false) > 0.20)
        #expect(FavoriteCardPalette.fillOpacity(isDark: true) < 0.5)
        #expect(FavoriteCardPalette.fillOpacity(isDark: false) < 0.5)
    }

    @Test func everyGlassSurfacePreservesItsForegroundSize() {
        _ = NSApplication.shared
        for size in [CGSize(width: 240, height: 32), CGSize(width: 240, height: 34),
                     CGSize(width: 240, height: 170), CGSize(width: 240, height: 36),
                     CGSize(width: 560, height: 320), CGSize(width: 960, height: 180)] {
            let foreground = Text("Early").frame(width: size.width, height: size.height)
            let plain = NSHostingView(rootView: foreground)
            let island = NSHostingView(rootView: foreground.background {
                BrowserIslandBackground(cornerRadius: 10, fillOpacity: 0.08, allowsTransparency: true)
            })
            let floating = NSHostingView(rootView: foreground.background {
                BrowserFloatingBackground(spaceColor: nil, cornerRadius: 16, allowsTransparency: true)
            })
            #expect(island.fittingSize == plain.fittingSize)
            #expect(floating.fittingSize == plain.fittingSize)
            #expect(island.window == nil && floating.window == nil)
        }
    }

    @Test func appearancePolicyDarkensGlassAndStrengthensLightSelections() {
        for role in BrowserGlassRole.allCases {
            let dark = BrowserSurfacePalette.darkeningOpacity(isDark: true, role: role)
            let light = BrowserSurfacePalette.darkeningOpacity(isDark: false, role: role)
            #expect(dark > light && dark >= 0.48 && dark < 0.75)
            #expect(light >= 0 && light < 0.05)
        }
        #expect(BrowserSurfacePalette.fillOpacity(0, isDark: false) == 0)
        #expect(BrowserSurfacePalette.fillOpacity(0.08, isDark: false) > 0.08)
        #expect(BrowserSurfacePalette.fillOpacity(0.12, isDark: false) > 0.12)
        #expect(BrowserSurfacePalette.borderOpacity(isDark: false) > BrowserSurfacePalette.borderOpacity(isDark: true))
    }

    @Test func renderedDarkSurfacesStayDarkAndLightSelectionRemainsVisible() throws {
        _ = NSApplication.shared
        var samples: [ColorScheme: [Double]] = [:]
        for scheme in [ColorScheme.light, .dark] {
            for opacity in [0.04, 0.12] {
                let renderer = ImageRenderer(content: BrowserIslandBackground(cornerRadius: 9,
                    fillOpacity: opacity, allowsTransparency: true)
                    .frame(width: 80, height: 44)
                    .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme))
                let pixel = try pixel(in: #require(renderer.cgImage), x: 40, y: 22)
                let brightness = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
                samples[scheme, default: []].append(brightness)
            }
        }
        let dark = try #require(samples[.dark]), light = try #require(samples[.light])
        #expect(dark.allSatisfy { $0 < 0.45 })
        #expect(light[0] - light[1] > 0.04)
        #expect(dark[1] > dark[0] && light[1] > dark[1])
    }

    @Test func postEffectMaskKeepsCanvasAndOuterCornersUnpainted() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: BrowserFrameGlassBackground(contentLeadingInset: 52,
                windowCornerRadius: 16, allowsTransparency: true)
                .frame(width: 180, height: 100).environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            for point in [CGPoint(x: 110, y: 50), CGPoint(x: 1, y: 1), CGPoint(x: 178, y: 98)] {
                #expect(try pixel(in: image, x: Int(point.x), y: Int(point.y))[3] == 0)
            }
        }
    }

    @Test func speakerAndCloseBackgroundIsHoverOnlyAndKeepsItsSize() throws {
        _ = NSApplication.shared
        for highlighted in [false, true] {
            let view = ZStack {
                Color.clear
                BrowserControlBackground(highlighted: highlighted)
            }.frame(width: 24, height: 24)
            let host = NSHostingView(rootView: view)
            #expect(host.fittingSize == CGSize(width: 24, height: 24))
            #expect(host.window == nil)
            let renderer = ImageRenderer(content: view)
            let center = try pixel(in: #require(renderer.cgImage), x: 12, y: 12)
            #expect(highlighted ? center[3] > 0 : center[3] == 0)
        }
    }

    @Test func nativeEditorAndPopoverDecorationDoesNotResizeContent() {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            for translucent in [false, true] {
                let foreground = Text("Name").frame(width: 340, height: 240)
                let plain = NSHostingView(rootView: foreground)
                let editor = NSHostingView(rootView: foreground.browserEditorPanel()
                    .environment(\.browserAllowsTransparency, translucent).environment(\.colorScheme, scheme))
                #expect(editor.fittingSize == plain.fittingSize)
                #expect(editor.window == nil)
            }
        }
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        let rendered = result.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -Double(x), y: -Double(y), width: Double(image.width), height: Double(image.height)))
            return true
        }
        try #require(rendered)
        return result
    }

    private func iconPixels(in image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 18 * 18 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 18, height: 18,
                bitsPerComponent: 8, bytesPerRow: 18 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -Double(image.width - 18) / 2,
                y: -Double(image.height - 18) / 2, width: Double(image.width), height: Double(image.height)))
            return true
        }
        try #require(rendered)
        return pixels
    }
}
