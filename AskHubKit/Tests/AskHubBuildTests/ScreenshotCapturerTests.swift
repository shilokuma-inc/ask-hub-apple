@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers

/// 判断のカードのスクショを撮る（ビルド → 入れ直し → 画面ごとに起動して、落ち着いてから撮る）
struct ScreenshotCapturerTests {
    static let simulator = Simulator(
        udid: "00000000-0000-0000-0000-000000000001",
        name: "askhub-worker-1-iPhone-17-Pro-iOS-27.0",
        runtime: "iOS-27-0",
        state: "Booted"
    )

    static let products = "/dd/Build/Products/Debug-iphonesimulator"
    static let buildSettings = #"""
        [
          {"target": "AppTests", "buildSettings": {"WRAPPER_EXTENSION": "xctest",
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test", "TARGET_BUILD_DIR": "\#(products)",
            "FULL_PRODUCT_NAME": "AppTests.xctest", "PRODUCT_BUNDLE_IDENTIFIER": "jp.example.AppTests"}},
          {"target": "App", "buildSettings": {"WRAPPER_EXTENSION": "app",
            "PRODUCT_TYPE": "com.apple.product-type.application", "TARGET_BUILD_DIR": "\#(products)",
            "FULL_PRODUCT_NAME": "App.app", "PRODUCT_BUNDLE_IDENTIFIER": "jp.example.App"}}
        ]
        """#

    /// `width`×`height` の 1 色の PNG
    static func png(width: Int, height: Int, gray: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 撮るたびに `frames` を順に返す（最後のものを返し続ける）Simulator と xcodebuild
    final class FakeDevice: Sendable {
        let frames: [Data]
        let shots = OSAllocatedUnfairLock(initialState: 0)
        let build: CommandResult

        init(frames: [Data], build: CommandResult = .output("")) {
            self.frames = frames
            self.build = build
        }

        func respond(_ command: Command) -> CommandResult {
            let arguments = command.arguments
            if arguments.starts(with: ["xcodebuild", "build"]) { return build }
            if arguments.starts(with: ["xcodebuild", "-showBuildSettings"]) { return .output(ScreenshotCapturerTests.buildSettings) }
            if arguments.starts(with: ["simctl", "io"]), let path = arguments.last {
                let index = shots.withLock { count in
                    defer { count += 1 }
                    return count
                }
                try? frames[min(index, frames.count - 1)].write(to: URL(fileURLWithPath: path))
            }
            return .output("")
        }
    }

    func capturer(_ device: FakeDevice, commands: FakeCommands) -> ScreenshotCapturer {
        ScreenshotCapturer(
            tools: BuildTools(xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"), temporaryDirectory: URL(fileURLWithPath: "/tmp")),
            runner: commands,
            timing: CaptureTiming(warmup: .zero, minimum: .seconds(1), interval: .seconds(1), limit: .seconds(4)),
            pause: { _ in }
        )
    }

    func request(_ output: URL) throws -> CaptureRequest {
        CaptureRequest(
            settings: try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS]),
            sourceDirectory: URL(fileURLWithPath: "/src"),
            derivedData: URL(fileURLWithPath: "/dd"),
            scenes: [
                .init(id: "inbox", title: "一覧", arguments: ["-demoScenario", "standard"]),
                .init(id: "empty", title: "空のとき", arguments: ["-demoScenario", "quiet"])
            ],
            output: output
        )
    }

    @Test func buildsInstallsAndShootsEachSceneWhenSettled() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        // 1 画面目は 2 枚目で落ち着く。2 画面目も同じ画面のまま
        let frames = [try Self.png(width: 1206, height: 2622, gray: 0.2), try Self.png(width: 1206, height: 2622, gray: 0.5)]
        let device = FakeDevice(frames: [frames[0], frames[1], frames[1]])
        let commands = FakeCommands { device.respond($0) }
        let outcome = try await capturer(device, commands: commands).capture(try request(output), on: Self.simulator)
        #expect(outcome.problem == nil)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.images.keys.sorted() == ["empty", "inbox"])
        // 縮めて置く（長い辺が 1400 まで）
        let inbox = try #require(outcome.images["inbox"])
        let image = try #require(CGImageSourceCreateWithURL(inbox as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1400)

        let udid = Self.simulator.udid
        let arguments = commands.arguments
        let build = ["xcodebuild", "build", "-project", "App.xcodeproj", "-scheme", "App", "-destination", "id=\(udid)"]
        #expect(arguments[0].starts(with: build))
        #expect(arguments[0].contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(arguments.contains(["simctl", "ui", udid, "appearance", "light"]))
        // 前の版のデータを残さないよう、消してから入れる
        let uninstall = try #require(arguments.firstIndex(of: ["simctl", "uninstall", udid, "jp.example.App"]))
        let install = try #require(arguments.firstIndex(of: ["simctl", "install", udid, "\(Self.products)/App.app"]))
        #expect(uninstall < install)
        // 画面ごとに、一覧の起動引数で起動し直す（シェルを通さずに渡す）
        #expect(arguments.contains(["simctl", "launch", udid, "jp.example.App", "-demoScenario", "quiet"]))
        #expect(arguments.last == ["simctl", "status_bar", udid, "clear"])
    }

    @Test func keepsLastFrameWhenScreenNeverSettles() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let frames = try (0..<10).map { try Self.png(width: 10, height: 20, gray: CGFloat($0) / 10) }
        let device = FakeDevice(frames: frames)
        let commands = FakeCommands { device.respond($0) }
        var request = try request(output)
        request.scenes = [request.scenes[0]]
        let outcome = try await capturer(device, commands: commands).capture(request, on: Self.simulator)
        #expect(outcome.images.keys.sorted() == ["inbox"])
        // 最初の 1 秒と、1 秒ごとに上限の 4 秒まで撮る
        #expect(device.shots.withLock { $0 } == 4)
    }

    @Test func reportsBuildFailureForEveryScene() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let device = FakeDevice(frames: [], build: .failure(65, "** BUILD FAILED **"))
        let commands = FakeCommands { device.respond($0) }
        let outcome = try await capturer(device, commands: commands).capture(try request(output), on: Self.simulator)
        #expect(outcome.problem == "アプリのビルドが通らない（終了コード 65）")
        #expect(outcome.failure(of: "inbox") == "アプリのビルドが通らない（終了コード 65）")
        #expect(!commands.arguments.contains { $0.first == "simctl" })
    }

    @Test func readsApplicationFromBuildSettings() {
        let app = ScreenshotCapturer.application(in: Data(Self.buildSettings.utf8))
        #expect(app == .init(path: URL(fileURLWithPath: "\(Self.products)/App.app"), bundleID: "jp.example.App"))
        #expect(ScreenshotCapturer.application(in: Data("[]".utf8)) == nil)
    }
}
