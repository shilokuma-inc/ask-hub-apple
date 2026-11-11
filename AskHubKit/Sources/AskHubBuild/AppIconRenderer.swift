import AskHubCommands
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 対象のアプリのアイコンの元（Icon Composer の `.icon` か、Asset Catalog の `.appiconset` のフォルダ）を、決めた大きさの PNG にする
/// （`docs/renewal/architecture.md` の「対象のアプリのアイコン」）
public struct AppIconRenderer: Sendable {
    public var tools: BuildTools
    public var runner: any CommandRunning
    /// 書き出す PNG の一辺（画素）。クライアントの一番大きいアイコン（札の裏の 68pt）を、3 倍の画面でもほぼ粗くなく描ける大きさ
    public var pixels: Int
    /// `ictool` の時間の上限
    public var timeout: Duration
    /// Icon Composer の `ictool`。nil なら、使う Xcode の中の Icon Composer から探す（`iconComposerTool`）
    public var ictool: URL?

    /// 読む画像の一辺の上限（画素）。大きすぎる画像を読んでメモリを使い切らないように、読む前に確かめる
    static let maximumSourcePixels = 4_096

    public init(
        tools: BuildTools,
        runner: any CommandRunning,
        pixels: Int = 256,
        timeout: Duration = .seconds(2 * 60),
        ictool: URL? = nil
    ) {
        self.tools = tools
        self.runner = runner
        self.pixels = pixels
        self.timeout = timeout
        self.ictool = ictool
    }

    /// PNG にする。`source` は取り出した元のフォルダ
    public func render(_ source: URL) async throws(AppIconRenderError) -> Data {
        switch source.pathExtension {
        case "icon": try await renderIconComposer(source)
        case "appiconset": try renderAssetCatalog(source)
        default: throw AppIconRenderError("アイコンの元が .icon でも .appiconset でもない（\(source.lastPathComponent)）")
        }
    }

    // MARK: - Icon Composer

    /// `xcrun ictool` で、iOS のライトの見た目を書き出す。iOS で書き出せない（macOS だけのアイコンなど）なら macOS で書き出す
    private func renderIconComposer(_ source: URL) async throws(AppIconRenderError) -> Data {
        let tool: URL
        if let ictool { tool = ictool } else { tool = try await iconComposerTool() }
        let output = tools.temporaryDirectory.appendingPathComponent("app-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        var failures: [String] = []
        for platform in ["iOS", "macOS"] {
            let arguments = [
                source.path, "--export-image", "--output-file", output.path, "--platform", platform,
                "--rendition", "Default", "--width", String(pixels), "--height", String(pixels), "--scale", "1"
            ]
            let command = Command(
                executable: tool,
                arguments: arguments,
                environment: tools.environment,
                workingDirectory: source.deletingLastPathComponent(),
                timeout: timeout
            )
            let result: CommandResult
            do {
                try FileManager.default.createDirectory(at: tools.temporaryDirectory, withIntermediateDirectories: true)
                result = try await runner.run(command)
            } catch {
                throw AppIconRenderError("ictool を起動できない（\(error.localizedDescription)）")
            }
            if result.succeeded, let data = try? Data(contentsOf: output) {
                return try Self.png(from: data, pixels: pixels)
            }
            failures.append("\(platform): \(Self.excerpt(of: result))")
        }
        throw AppIconRenderError("ictool で書き出せない（\(failures.joined(separator: "、"))）")
    }

    /// 使う Xcode（`DEVELOPER_DIR`。決めていなければ `xcode-select -p`）の中の Icon Composer の `ictool`。
    /// `xcrun ictool` が見つける `Contents/Developer/usr/bin/ictool` は Asset Catalog 用の別のもので、`--export-image` を受け付けない
    func iconComposerTool() async throws(AppIconRenderError) -> URL {
        let developer: URL
        if let directory = tools.developerDirectory {
            developer = directory
        } else {
            let command = Command(
                executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["-p"],
                environment: tools.environment,
                workingDirectory: URL(fileURLWithPath: "/"),
                timeout: .seconds(30)
            )
            guard let result = try? await runner.run(command), result.succeeded,
                  let path = String(bytes: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                throw AppIconRenderError("使う Xcode が分からない（xcode-select -p が失敗した）")
            }
            developer = URL(fileURLWithPath: path, isDirectory: true)
        }
        let tool = Self.iconComposerTool(in: developer)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw AppIconRenderError("Xcode に Icon Composer の ictool が無い（\(tool.path)。Xcode 26 から入っている）")
        }
        return tool
    }

    /// `Xcode.app/Contents/Developer` から見た、Icon Composer の `ictool`
    static func iconComposerTool(in developer: URL) -> URL {
        developer.deletingLastPathComponent().appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
    }

    private static func excerpt(of result: CommandResult) -> String {
        if result.timedOut { return "時間内に終わらない" }
        let text = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "終了コード \(result.status)" : String(text.suffix(300))
    }

    // MARK: - Asset Catalog

    /// `Contents.json` のうち、いちばん大きいライトの画像を縮める
    private func renderAssetCatalog(_ source: URL) throws(AppIconRenderError) -> Data {
        guard let contents = try? Data(contentsOf: source.appendingPathComponent("Contents.json")) else {
            throw AppIconRenderError("\(source.lastPathComponent) に Contents.json が無い")
        }
        guard let name = Self.largestImage(inContents: contents),
              let data = try? Data(contentsOf: source.appendingPathComponent(name)) else {
            throw AppIconRenderError("\(source.lastPathComponent) に読める画像が無い")
        }
        return try Self.png(from: data, pixels: pixels)
    }

    /// `Contents.json` の画像のうち、いちばん大きいもののファイル名。ダーク・ティントの見た目（`appearances`）があるものは、ライトが無いときだけ選ぶ。
    /// フォルダの外を指す名前は選ばない
    static func largestImage(inContents data: Data) -> String? {
        guard let contents = try? JSONDecoder().decode(AssetCatalogContents.self, from: data) else { return nil }
        let images = contents.images.filter { image in
            guard let name = image.filename else { return false }
            return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        }
        return images.max { ($0.isLight ? 1 : 0, $0.pixels) < ($1.isLight ? 1 : 0, $1.pixels) }?.filename
    }

    // MARK: - PNG

    /// 画像を、一辺が `pixels` までの PNG にする（元の画像のメタデータは写さない）
    static func png(from data: Data, pixels: Int) throws(AppIconRenderError) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw AppIconRenderError("画像として読めない")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, max(width, height) <= maximumSourcePixels else {
            throw AppIconRenderError("画像の大きさが読めないか、大きすぎる（\(width)×\(height)）")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppIconRenderError("画像を縮められない")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AppIconRenderError("PNG を作れない")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppIconRenderError("PNG を書き出せない") }
        return output as Data
    }
}

public struct AppIconRenderError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Asset Catalog の `Contents.json`（使う欄だけ）
/// Asset Catalog の `Contents.json`（使う欄だけ）
private struct AssetCatalogContents: Decodable {
    struct Image: Decodable {
        var filename: String?
        /// `1024x1024`・`60x60` など（pt）
        var size: String?
        /// `2x` など。無ければ 1 倍
        var scale: String?
        var appearances: [Appearance]?

        /// 一辺の画素
        var pixels: Double {
            let side = size?.split(separator: "x").first.flatMap { Double($0) } ?? 0
            let factor = scale.flatMap { Double($0.dropLast()) } ?? 1
            return side * factor
        }

        /// ライトの見た目か（ダーク・ティントの見た目は `appearances` を持つ）
        var isLight: Bool { appearances?.isEmpty ?? true }
    }

    /// ダーク・ティントの見た目（中身は見ない）
    struct Appearance: Decodable {}

    var images: [Image]
}
