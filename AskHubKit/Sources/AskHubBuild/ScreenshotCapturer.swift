import AskHubCommands
import AskHubProtocol
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 1 つの版（base との分岐点か、作業ブランチの先頭）のアプリで、画面ごとに撮る依頼
public struct CaptureRequest: Equatable, Sendable {
    /// プロジェクトとスキーム（`build.xcode`）
    public var settings: BuildSettings
    /// ビルドする写し
    public var sourceDirectory: URL
    /// この版の DerivedData（base と作業ブランチの先頭で分ける。写しのパスが違うと、同じ DerivedData を使い回せない）
    public var derivedData: URL
    /// 撮る画面（並べた順に撮る）
    public var scenes: [ScreenshotScenesFile.Scene]
    /// 撮った画像（`<画面の id>.png`）を置くフォルダ
    public var output: URL

    public init(settings: BuildSettings, sourceDirectory: URL, derivedData: URL, scenes: [ScreenshotScenesFile.Scene], output: URL) {
        self.settings = settings
        self.sourceDirectory = sourceDirectory
        self.derivedData = derivedData
        self.scenes = scenes
        self.output = output
    }
}

/// 撮った結果
public struct CaptureOutcome: Equatable, Sendable {
    /// 撮れた画面（画面の id → 画像のファイル）
    public var images: [String: URL]
    /// 撮れなかった画面と、そのわけ（人が読む）
    public var failures: [String: String]
    /// ビルド・インストールなど、どの画面も撮れなかったわけ
    public var problem: String?

    public init(images: [String: URL] = [:], failures: [String: String] = [:], problem: String? = nil) {
        self.images = images
        self.failures = failures
        self.problem = problem
    }

    /// `scene` を撮れなかったわけ。撮れていれば nil
    public func failure(of scene: String) -> String? {
        images[scene] == nil ? failures[scene] ?? problem ?? "撮れなかった" : nil
    }
}

/// 待ち方
public struct CaptureTiming: Equatable, Sendable {
    /// インストールの直後に 1 回起動して待つ長さ（初回の起動は遅く、ホーム画面を撮ってしまう）
    public var warmup: Duration
    /// 起動してから最初に撮るまでの長さ
    public var minimum: Duration
    /// 落ち着いたか（続けて撮った 2 枚が同じか）を見る間隔
    public var interval: Duration
    /// 落ち着くのを待つ上限。過ぎたら、最後に撮ったものを使う
    public var limit: Duration
    /// `xcodebuild build` の上限
    public var build: Duration
    /// `simctl` の 1 回の上限
    public var simctl: Duration

    public init(
        warmup: Duration = .seconds(10),
        minimum: Duration = .seconds(3),
        interval: Duration = .seconds(1),
        limit: Duration = .seconds(30),
        build: Duration = .seconds(30 * 60),
        simctl: Duration = .seconds(2 * 60)
    ) {
        self.warmup = warmup
        self.minimum = minimum
        self.interval = interval
        self.limit = limit
        self.build = build
        self.simctl = simctl
    }
}

/// 判断のカードのスクショを撮る（`docs/renewal/flows.md` の「スクショ」）。
///
/// 版のアプリを Simulator 向けにビルドして入れ直し、画面ごとに、撮れる画面の一覧の起動引数でアプリを起動し直して、
/// 画面が落ち着いて（続けて撮った 2 枚が同じになって）から撮る。上端（時刻・電池）と外観（ライト）は固定し、差が画面の変化だけになるようにする。
/// 撮った画像は、長い辺を `maximumPixels` まで縮めて PNG で置く。Simulator は呼ぶ側が枠から用意する（`SimulatorPool.prepare`）
public struct ScreenshotCapturer: Sendable {
    /// 撮った画像の長い辺の上限（iPhone 17 Pro の 2622 を半分ほどにする）
    public static let maximumPixels = 1400

    public var tools: BuildTools
    public var runner: any CommandRunning
    public var timing: CaptureTiming
    /// 待つ（テストでは待たずに返す）
    public var pause: @Sendable (Duration) async throws -> Void

    public init(
        tools: BuildTools,
        runner: any CommandRunning,
        timing: CaptureTiming = CaptureTiming(),
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.tools = tools
        self.runner = runner
        self.timing = timing
        self.pause = pause
    }

    /// 撮る。失敗も結果として返し、投げるのは取り消されたときだけ
    public func capture(_ request: CaptureRequest, on simulator: Simulator) async throws(CancellationError) -> CaptureOutcome {
        guard !request.scenes.isEmpty else { return CaptureOutcome() }
        do {
            try FileManager.default.createDirectory(at: request.output, withIntermediateDirectories: true)
        } catch {
            return CaptureOutcome(problem: "撮った画像の置き場所を作れない（\(error.localizedDescription)）")
        }
        let app: BuiltApp
        switch try await build(request, for: simulator) {
        case let .success(built): app = built
        case let .failure(problem): return CaptureOutcome(problem: problem.message)
        }
        if let problem = try await install(app, on: simulator, warmingUpWith: request.scenes[0]) {
            return CaptureOutcome(problem: problem)
        }
        var outcome = CaptureOutcome()
        for scene in request.scenes {
            let file = request.output.appendingPathComponent("\(scene.id).png")
            if let failure = try await shoot(scene, of: app, on: simulator, to: file) {
                outcome.failures[scene.id] = failure
            } else {
                outcome.images[scene.id] = file
            }
        }
        _ = try await simctl(["terminate", simulator.udid, app.bundleID])
        _ = try await simctl(["status_bar", simulator.udid, "clear"])
        return outcome
    }

    // MARK: - ビルドと準備

    /// ビルドしたアプリ
    struct BuiltApp: Equatable {
        var path: URL
        var bundleID: String
    }

    struct Problem: Error {
        var message: String
    }

    private func build(_ request: CaptureRequest, for simulator: Simulator) async throws(CancellationError) -> Result<BuiltApp, Problem> {
        let common = Self.arguments(request, simulator: simulator)
        let result = try await xcrun(
            ["xcodebuild", "build"] + common + Self.buildOptions, in: request.sourceDirectory, timeout: timing.build
        )
        guard result.succeeded else {
            let reason = result.timedOut ? "時間内に終わらない" : "終了コード \(result.status)"
            return .failure(Problem(message: "アプリのビルドが通らない（\(reason)）"))
        }
        let settings = try await xcrun(
            ["xcodebuild", "-showBuildSettings", "-json"] + common, in: request.sourceDirectory, timeout: timing.simctl
        )
        guard settings.succeeded, let app = Self.application(in: settings.standardOutput) else {
            return .failure(Problem(message: "ビルドしたアプリの場所を読めない（xcodebuild -showBuildSettings）"))
        }
        return .success(app)
    }

    /// `xcodebuild build` と `-showBuildSettings` に共通の引数
    static func arguments(_ request: CaptureRequest, simulator: Simulator) -> [String] {
        [
            request.settings.projectOption, request.settings.project,
            "-scheme", request.settings.scheme,
            "-destination", "id=\(simulator.udid)",
            "-derivedDataPath", request.derivedData.path
        ]
    }

    /// ビルドだけに付けるもの（新しい DerivedData で止まらないように・索引を作らない・署名しない）
    static let buildOptions = [
        "-skipPackagePluginValidation", "-skipMacroValidation", "COMPILER_INDEX_STORE_ENABLE=NO", "CODE_SIGNING_ALLOWED=NO"
    ]

    /// `-showBuildSettings -json` の出力から、アプリのターゲットの置き場所と Bundle ID を読む
    static func application(in output: Data) -> BuiltApp? {
        struct Entry: Decodable {
            var buildSettings: [String: String]
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: output) else { return nil }
        let app = entries.lazy.map(\.buildSettings).first { settings in
            settings["WRAPPER_EXTENSION"] == "app" && settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
        }
        guard let app, let directory = app["TARGET_BUILD_DIR"] ?? app["BUILT_PRODUCTS_DIR"], let name = app["FULL_PRODUCT_NAME"],
              let bundleID = app["PRODUCT_BUNDLE_IDENTIFIER"], !bundleID.isEmpty else {
            return nil
        }
        return BuiltApp(path: URL(fileURLWithPath: directory).appendingPathComponent(name), bundleID: bundleID)
    }

    /// 上端と外観を固定し、前に入れたもの（前の版のデータ）を消してから入れ直す。入れた直後に 1 回起動して待つ
    private func install(
        _ app: BuiltApp,
        on simulator: Simulator,
        warmingUpWith scene: ScreenshotScenesFile.Scene
    ) async throws(CancellationError) -> String? {
        let statusBar = [
            "status_bar", simulator.udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100", "--operatorName", ""
        ]
        _ = try await simctl(statusBar)
        _ = try await simctl(["ui", simulator.udid, "appearance", "light"])
        _ = try await simctl(["uninstall", simulator.udid, app.bundleID])
        let installed = try await simctl(["install", simulator.udid, app.path.path])
        guard installed.succeeded else { return "アプリを Simulator に入れられない（終了コード \(installed.status)）" }
        _ = try await simctl(["launch", simulator.udid, app.bundleID] + scene.arguments)
        try await wait(timing.warmup)
        _ = try await simctl(["terminate", simulator.udid, app.bundleID])
        return nil
    }

    // MARK: - 撮る

    /// 1 画面を撮って `file` に置く。撮れなければ、わけを返す
    private func shoot(
        _ scene: ScreenshotScenesFile.Scene,
        of app: BuiltApp,
        on simulator: Simulator,
        to file: URL
    ) async throws(CancellationError) -> String? {
        _ = try await simctl(["terminate", simulator.udid, app.bundleID])
        let launched = try await simctl(["launch", simulator.udid, app.bundleID] + scene.arguments)
        guard launched.succeeded else { return "アプリを起動できない（終了コード \(launched.status)）" }
        try await wait(timing.minimum)
        let raw = file.deletingPathExtension().appendingPathExtension("raw.png")
        defer { try? FileManager.default.removeItem(at: raw) }
        var previous: Data?
        var waited = timing.minimum
        while true {
            let shot = try await simctl(["io", simulator.udid, "screenshot", "--type=png", raw.path])
            guard shot.succeeded, let data = try? Data(contentsOf: raw) else { return "画面を撮れない（終了コード \(shot.status)）" }
            // 時刻は上端で固定しているので、アニメーションが終われば画面は変わらない。上限まで動き続けたら、最後に撮ったものを使う
            if data == previous || waited >= timing.limit { break }
            previous = data
            try await wait(timing.interval)
            waited += timing.interval
        }
        guard Self.downscale(raw, to: file, maximumPixels: Self.maximumPixels) else { return "撮った画像を縮められない" }
        return nil
    }

    /// 長い辺を `maximumPixels` までに縮めて PNG で書く（小さければそのまま書き直す）
    static func downscale(_ source: URL, to destination: URL, maximumPixels: Int) -> Bool {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(output, thumbnail, nil)
        return CGImageDestinationFinalize(output)
    }

    // MARK: - コマンド

    private func wait(_ duration: Duration) async throws(CancellationError) {
        do {
            try await pause(duration)
        } catch {
            throw CancellationError()
        }
    }

    private func simctl(_ arguments: [String]) async throws(CancellationError) -> CommandResult {
        try await xcrun(["simctl"] + arguments, in: tools.temporaryDirectory, timeout: timing.simctl)
    }

    /// 流して結果を返す。起動できなければ失敗の結果にし、投げるのは取り消されたときだけ
    private func xcrun(_ arguments: [String], in directory: URL, timeout: Duration) async throws(CancellationError) -> CommandResult {
        do {
            let result = try await runner.run(tools.command(arguments, in: directory, timeout: timeout))
            if Task.isCancelled { throw CancellationError() }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CommandResult(status: -1, standardOutput: Data(), standardError: Data(error.localizedDescription.utf8))
        }
    }
}
