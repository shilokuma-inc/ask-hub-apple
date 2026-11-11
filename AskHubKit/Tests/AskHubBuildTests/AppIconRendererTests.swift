@testable import AskHubBuild
import AskHubCommands
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

struct AppIconRendererTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppIconRendererTests-\(UUID().uuidString)")
    var tools: BuildTools { BuildTools(temporaryDirectory: root.appendingPathComponent("tmp")) }

    @Test func picksLargestLightImageOfAssetCatalog() throws {
        let contents = #"""
            {
              "images": [
                { "filename": "Icon-60@3x.png", "idiom": "iphone", "size": "60x60", "scale": "3x" },
                { "filename": "Icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
                { "filename": "Icon-1024-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
                  "appearances": [{ "appearance": "luminosity", "value": "dark" }] },
                { "idiom": "universal", "platform": "ios", "size": "2048x2048" },
                { "filename": "../outside.png", "idiom": "universal", "size": "4096x4096" }
              ],
              "info": { "author": "xcode", "version": 1 }
            }
            """#
        #expect(AppIconRenderer.largestImage(inContents: Data(contents.utf8)) == "Icon-1024.png")
    }

    @Test func picksDarkImageOnlyWithoutLightOne() {
        let contents = #"""
            {"images": [{ "filename": "dark.png", "size": "1024x1024", "appearances": [{ "appearance": "luminosity", "value": "dark" }] }]}
            """#
        #expect(AppIconRenderer.largestImage(inContents: Data(contents.utf8)) == "dark.png")
        #expect(AppIconRenderer.largestImage(inContents: Data(#"{"images": []}"#.utf8)) == nil)
        #expect(AppIconRenderer.largestImage(inContents: Data("not json".utf8)) == nil)
    }

    @Test func shrinksImageToPNGOfGivenSize() throws {
        let png = try AppIconRenderer.png(from: Self.image(side: 1024), pixels: 256)
        #expect(try Self.size(of: png) == [256, 256])
        // 小さい画像は引き伸ばさない
        let small = try AppIconRenderer.png(from: Self.image(side: 120), pixels: 256)
        #expect(try Self.size(of: small) == [120, 120])
        #expect(throws: AppIconRenderError.self) { try AppIconRenderer.png(from: Data("not an image".utf8), pixels: 256) }
    }

    @Test func rendersAssetCatalog() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try Data(#"{"images": [{ "filename": "icon.png", "idiom": "universal", "size": "1024x1024" }]}"#.utf8)
            .write(to: set.appendingPathComponent("Contents.json"))
        try Self.image(side: 1024).write(to: set.appendingPathComponent("icon.png"))
        let commands = FakeCommands { _ in .failure(1, "") }
        let png = try await AppIconRenderer(tools: tools, runner: commands).render(set)
        #expect(try Self.size(of: png) == [256, 256])
        #expect(commands.commands.isEmpty)
    }

    @Test func rendersIconComposerWithIctoolAndFallsBackToMacOS() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let icon = root.appendingPathComponent("App/AppIcon.icon")
        try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
        let image = try Self.image(side: 256)
        // iOS では書き出せず、macOS で書き出せる ictool
        let commands = FakeCommands { command in
            let arguments = command.arguments
            guard let platform = arguments.firstIndex(of: "--platform").map({ arguments[$0 + 1] }), platform == "macOS",
                  let output = arguments.firstIndex(of: "--output-file").map({ arguments[$0 + 1] }) else {
                return .failure(1, "the icon does not support iOS")
            }
            try? image.write(to: URL(fileURLWithPath: output))
            return .output("{\n\n}")
        }
        let png = try await AppIconRenderer(tools: tools, runner: commands, ictool: Self.ictool).render(icon)
        #expect(try Self.size(of: png) == [256, 256])
        #expect(commands.commands.map(\.executable) == [Self.ictool, Self.ictool])
        #expect(commands.arguments.map { Array($0.prefix(2)) } == [[icon.path, "--export-image"], [icon.path, "--export-image"]])
        let first = try #require(commands.arguments.first)
        #expect(first.suffix(10) == ["--platform", "iOS", "--rendition", "Default", "--width", "256", "--height", "256", "--scale", "1"])
        // 書き出した画像は消す
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tools.temporaryDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func reportsIctoolFailures() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let icon = root.appendingPathComponent("AppIcon.icon")
        try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
        let renderer = AppIconRenderer(tools: tools, runner: FakeCommands { _ in .failure(1, "broken icon.json") }, ictool: Self.ictool)
        await #expect(throws: AppIconRenderError("ictool で書き出せない（iOS: broken icon.json、macOS: broken icon.json）")) {
            try await renderer.render(icon)
        }
        await #expect(throws: AppIconRenderError.self) { try await renderer.render(root.appendingPathComponent("Icon.png")) }
    }

    /// 本物の `xcrun ictool` で、このリポジトリのアイコンを書き出す。`ASKHUB_LIVE_BUILD=1` のときだけ動く
    @Test(.enabled(if: LiveBuild.isEnabled)) func rendersOwnIconWithRealIctool() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../AskHub/AppIcon.icon").standardizedFileURL
        let png = try await AppIconRenderer(tools: tools, runner: ProcessCommandRunner()).render(icon)
        #expect(try Self.size(of: png) == [256, 256])
    }

    @Test func findsIconComposerToolInDeveloperDirectory() {
        let developer = URL(fileURLWithPath: "/Applications/Xcode-26.6.0.app/Contents/Developer", isDirectory: true)
        #expect(
            AppIconRenderer.iconComposerTool(in: developer).path
                == "/Applications/Xcode-26.6.0.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
        )
    }

    // MARK: -

    static let ictool = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")

    /// 一辺 `side` の、塗りつぶした PNG
    static func image(side: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func size(of png: Data) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return [image.width, image.height]
    }
}
