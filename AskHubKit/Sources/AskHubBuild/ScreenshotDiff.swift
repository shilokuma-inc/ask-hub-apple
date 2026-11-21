import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 2 枚のスクショを比べた結果
public struct ScreenshotDifference: Equatable, Sendable {
    /// 違う
    public var changed: Bool
    /// 違う所（画像の幅・高さに対する割合。x・y・幅・高さ）。差が無い・大きさが違うなどで比べられないときは nil
    public var area: CGRect?

    public init(changed: Bool, area: CGRect? = nil) {
        self.changed = changed
        self.area = area
    }
}

/// スクショを比べ、人に見せる見本を作る（`docs/renewal/release.md` の「スクショ」）
public enum ScreenshotDiff {
    /// 色の違いをこれより小さければ同じとみなす（0〜255。圧縮や色の扱いの小さな揺れを差にしない）
    static let channelTolerance = 24
    /// 違う画素がこの割合より少なければ同じとみなす（カーソルの点滅などのごく小さな違い）
    static let pixelTolerance = 0.0005

    /// 比べる。大きさが違う・読めないときは「違う（所は分からない）」にする
    public static func compare(before: Data, after: Data) -> ScreenshotDifference {
        guard let old = pixels(of: before), let new = pixels(of: after) else { return ScreenshotDifference(changed: true) }
        guard old.width == new.width, old.height == new.height else { return ScreenshotDifference(changed: true) }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in 0..<new.height {
            for x in 0..<new.width {
                let offset = (y * new.width + x) * 4
                var differs = false
                for channel in 0..<3 where abs(Int(old.bytes[offset + channel]) - Int(new.bytes[offset + channel])) > channelTolerance {
                    differs = true
                }
                guard differs else { continue }
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard Double(count) / Double(new.width * new.height) >= pixelTolerance, maxX >= 0 else {
            return ScreenshotDifference(changed: false)
        }
        let area = CGRect(
            x: Double(minX) / Double(new.width),
            y: Double(minY) / Double(new.height),
            width: Double(maxX - minX + 1) / Double(new.width),
            height: Double(maxY - minY + 1) / Double(new.height)
        )
        return ScreenshotDifference(changed: true, area: area)
    }

    /// 人に見せる見本（幅を `width` まで縮めた JPEG）。読めなければ nil
    public static func preview(of data: Data, width: Int = 600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: width * 3,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = min(1, Double(width) / Double(full.width))
        let size = (width: max(1, Int(Double(full.width) * scale)), height: max(1, Int(Double(full.height) * scale)))
        guard let context = Self.context(width: size.width, height: size.height, data: nil, alpha: .noneSkipLast) else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// sRGB の 8 ビットの描き先
    private static func context(width: Int, height: Int, data: UnsafeMutableRawPointer?, alpha: CGImageAlphaInfo) -> CGContext? {
        CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: data == nil ? 0 : width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha.rawValue
        )
    }

    /// 画像の画素（sRGB の RGBA 8 ビット）
    struct Pixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    private static func pixels(of data: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = context(width: width, height: height, data: buffer.baseAddress, alpha: .premultipliedLast) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }
}
