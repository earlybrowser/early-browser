import CoreGraphics
import Foundation
import ImageIO

/// An appearance-independent icon color, cached with the artwork rather than
/// resampled during SwiftUI rendering. Transparent padding contributes nothing.
public struct FaviconColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    static func extract(from data: Data) -> Self? {
        guard data.count <= FaviconLoader.byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        struct Bucket {
            var weight = 0.0
            var sum = SIMD3<Double>.zero
        }
        var all: [Int: Bucket] = [:], colorful: [Int: Bucket] = [:]
        var visibleWeight = 0.0, colorfulWeight = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha >= 0.15 else { continue }
            // CGContext produces premultiplied RGBA; recover the actual hue
            // before clustering, and weight translucent edges by their alpha.
            let rgb = SIMD3<Double>(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2])) / (255 * alpha)
            let key = (Int(rgb.x * 255) >> 5) << 6 | (Int(rgb.y * 255) >> 5) << 3 | (Int(rgb.z * 255) >> 5)
            all[key, default: Bucket()].weight += alpha
            all[key, default: Bucket()].sum += rgb * alpha
            visibleWeight += alpha
            if max(rgb.x, rgb.y, rgb.z) - min(rgb.x, rgb.y, rgb.z) > 0.12 {
                colorful[key, default: Bucket()].weight += alpha
                colorful[key, default: Bucket()].sum += rgb * alpha
                colorfulWeight += alpha
            }
        }
        // Favor the brand's dominant hue over a plain white/black backing when
        // enough colored artwork exists. Monochrome icons keep a neutral tint.
        let buckets = colorfulWeight >= visibleWeight * 0.08 ? colorful : all
        guard let winner = buckets.keys.sorted().max(by: { buckets[$0]!.weight < buckets[$1]!.weight }),
              let bucket = buckets[winner], bucket.weight > 0 else { return nil }
        let rgb = bucket.sum / bucket.weight
        return Self(red: rgb.x, green: rgb.y, blue: rgb.z)
    }
}
