import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EarlyWeb

struct FaviconColorTests {
    @Test func dominantHueIsNotAnAverageAndIgnoresTransparentPadding() throws {
        let icon = try png { x, _ in
            if x < 4 { return [255, 0, 0, 0] }
            return x < 13 ? [0, 0, 255, 255] : [255, 0, 0, 255]
        }
        let color = try #require(FaviconColor.extract(from: icon))
        #expect(color.blue > 0.95)
        #expect(color.red < 0.05)
        #expect(color.green < 0.05)
    }

    @Test func brandColorWinsOverPlainBackingAndMonochromeStaysNeutral() throws {
        let icon = try png { x, y in
            (4..<12).contains(x) && (4..<12).contains(y) ? [0, 180, 0, 255] : [255, 255, 255, 255]
        }
        let green = try #require(FaviconColor.extract(from: icon))
        #expect(green.green > 0.65)
        #expect(green.red < 0.05 && green.blue < 0.05)
        let monochrome = try png { _, _ in [80, 80, 80, 255] }
        let gray = try #require(FaviconColor.extract(from: monochrome))
        #expect(abs(gray.red - gray.green) < 0.01)
        #expect(abs(gray.green - gray.blue) < 0.01)
    }

    @Test func missingOrInvisibleArtworkHasNoTint() throws {
        #expect(FaviconColor.extract(from: Data("not an icon".utf8)) == nil)
        #expect(FaviconColor.extract(from: Data(repeating: 0, count: FaviconLoader.byteLimit + 1)) == nil)
        let transparent = try png { _, _ in [0, 0, 255, 0] }
        #expect(FaviconColor.extract(from: transparent) == nil)
    }

    private func png(pixel: (Int, Int) -> [UInt8]) throws -> Data {
        let bytes = (0..<16).flatMap { y in (0..<16).flatMap { x in pixel(x, y) } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
