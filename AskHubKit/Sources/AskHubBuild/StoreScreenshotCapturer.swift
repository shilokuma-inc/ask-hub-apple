import AskHubCommands
import AskHubProtocol
import Foundation

/// UI テストが添付した 1 枚のスクショ
public struct CapturedShot: Equatable, Sendable {
    /// 添付の名前（`01-ホーム` など）
    public var name: String
    public var file: URL

    public init(name: String, file: URL) {
        self.name = name
        self.file = file
    }
}

/// App Store のスクショを、リポジトリの UI テストで撮る（`docs/renewal/release.md` の「スクショ」）。
///
/// テストのビルドは 1 回だけ（`buildForTesting`）にし、機種・言語ごとに `xcodebuild test-without-building -only-testing:` で流す。
/// 言語などは `TEST_RUNNER_<名前>` でテストの環境変数に渡す。流した後、結果（xcresult）の添付を `xcresulttool export attachments` で取り出し、
/// 画像の添付を添付した順に返す。上端（時刻・電池）と外観（ライト）は流す前に固定し、画面が同じなら同じ画像になるようにする
public struct StoreScreenshotCapturer: Sendable {
    public var tools: BuildTools
    public var runner: any CommandRunning
    public var timing: CaptureTiming

    public init(tools: BuildTools, runner: any CommandRunning, timing: CaptureTiming = CaptureTiming()) {
        self.tools = tools
        self.runner = runner
        self.timing = timing
    }

    /// テストをビルドする。通らなければ理由を返す
    public func buildForTesting(
        _ settings: BuildSettings,
        sourceDirectory: URL,
        derivedData: URL,
        on simulator: Simulator
    ) async throws(CancellationError) -> String? {
        if let generator = settings.generate {
            let generation = ProjectGeneration(tools: tools, runner: runner, timeout: timing.generate)
            if case let .failure(failure) = try await generation.run(settings, in: sourceDirectory) {
                return failure.summary(of: generator)
            }
        }
        let arguments = ["xcodebuild", "build-for-testing"] + Self.common(settings, simulator: simulator, derivedData: derivedData)
            + ScreenshotCapturer.buildOptions
        let result = try await xcrun(arguments, in: sourceDirectory, timeout: timing.build)
        guard result.succeeded else {
            return "UI テストのビルドが通らない（\(result.timedOut ? "時間内に終わらない" : "終了コード \(result.status)")）"
        }
        return nil
    }

    /// 1 回の UI テスト（1 つの機種・環境変数）
    public struct Run: Sendable {
        public var settings: BuildSettings
        /// `-only-testing:` の値
        public var test: String
        public var environment: [String: String]
        public var sourceDirectory: URL
        public var derivedData: URL
        /// 結果と画像を置くフォルダ（毎回新しく作る）
        public var output: URL

        public init(
            settings: BuildSettings,
            test: String,
            environment: [String: String],
            sourceDirectory: URL,
            derivedData: URL,
            output: URL
        ) {
            self.settings = settings
            self.test = test
            self.environment = environment
            self.sourceDirectory = sourceDirectory
            self.derivedData = derivedData
            self.output = output
        }
    }

    /// UI テストを流し、添付の画像を添付した順に返す
    public func run(_ run: Run, on simulator: Simulator) async throws(CancellationError) -> Result<[CapturedShot], CaptureFailure> {
        let (settings, output) = (run.settings, run.output)
        let bundle = output.appendingPathComponent("result.xcresult")
        let attachments = output.appendingPathComponent("attachments")
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        } catch {
            return .failure(CaptureFailure("撮った画像の置き場所を作れない（\(error.localizedDescription)）"))
        }
        _ = try await xcrun(["simctl"] + Self.statusBar(simulator), in: tools.temporaryDirectory, timeout: timing.simctl)
        _ = try await xcrun(["simctl", "ui", simulator.udid, "appearance", "light"], in: tools.temporaryDirectory, timeout: timing.simctl)
        let arguments = ["xcodebuild", "test-without-building"] + Self.common(settings, simulator: simulator, derivedData: run.derivedData)
            + ["-only-testing:\(run.test)", "-resultBundlePath", bundle.path] + Self.testEnvironment(run.environment)
        let result = try await xcrun(arguments, in: run.sourceDirectory, timeout: timing.build)
        // テストが落ちても、落ちる前に撮った画像は使わない（揃わない組を App Store に出さない）
        guard result.succeeded else {
            return .failure(CaptureFailure("UI テストが通らない（\(result.timedOut ? "時間内に終わらない" : "終了コード \(result.status)")）"))
        }
        let export = try await xcrun(
            ["xcresulttool", "export", "attachments", "--path", bundle.path, "--output-path", attachments.path],
            in: tools.temporaryDirectory,
            timeout: timing.simctl
        )
        guard export.succeeded, let manifest = try? Data(contentsOf: attachments.appendingPathComponent("manifest.json")) else {
            return .failure(CaptureFailure("UI テストの添付を取り出せない（xcresulttool export attachments）"))
        }
        let shots = Self.images(in: manifest, directory: attachments)
        guard !shots.isEmpty else { return .failure(CaptureFailure("UI テストが画像を添付していない")) }
        guard shots.count <= StoreScreenshotSettings.maximumShots else {
            return .failure(CaptureFailure("UI テストの画像が \(StoreScreenshotSettings.maximumShots) 枚を超えている（App Store の上限）"))
        }
        return .success(shots)
    }

    /// `xcodebuild` に共通の引数
    static func common(_ settings: BuildSettings, simulator: Simulator, derivedData: URL) -> [String] {
        [
            settings.projectOption, settings.project,
            "-scheme", settings.scheme,
            "-destination", "id=\(simulator.udid)",
            "-derivedDataPath", derivedData.path
        ]
    }

    /// テストの環境変数（`TEST_RUNNER_<名前>=<値>` で xcodebuild がテストに渡す）。名前の順にそろえる
    static func testEnvironment(_ environment: [String: String]) -> [String] {
        environment.sorted { $0.key < $1.key }.map { "TEST_RUNNER_\($0.key)=\($0.value)" }
    }

    /// 上端を固定する（判断のカードの撮影と同じ値）
    static func statusBar(_ simulator: Simulator) -> [String] {
        [
            "status_bar", simulator.udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100"
        ]
    }

    /// `manifest.json` から、画像の添付を添付した順に読む（失敗に結びついた添付は使わない）
    static func images(in manifest: Data, directory: URL) -> [CapturedShot] {
        struct Attachment: Decodable {
            var exportedFileName: String
            var suggestedHumanReadableName: String
            var isAssociatedWithFailure: Bool
            var timestamp: Double?
        }
        struct Test: Decodable {
            var attachments: [Attachment]
        }
        guard let tests = try? JSONDecoder().decode([Test].self, from: manifest) else { return [] }
        let extensions: Set = ["png", "jpg", "jpeg", "heic"]
        let images = tests.flatMap(\.attachments).filter { attachment in
            let fileExtension = (attachment.exportedFileName as NSString).pathExtension.lowercased()
            return !attachment.isAssociatedWithFailure && extensions.contains(fileExtension) && !attachment.exportedFileName.contains("/")
        }
        let ordered = images.enumerated().sorted { lhs, rhs in
            (lhs.element.timestamp ?? 0, lhs.offset) < (rhs.element.timestamp ?? 0, rhs.offset)
        }
        return ordered.map { _, attachment in
            let file = directory.appendingPathComponent(attachment.exportedFileName)
            return CapturedShot(name: Self.name(attachment.suggestedHumanReadableName), file: file)
        }
    }

    /// 添付の名前（`01-ホーム_0_<UUID>.png` のような書き出しの名前から、付け足された番号・拡張子を除く）
    static func name(_ suggested: String) -> String {
        let base = (suggested as NSString).deletingPathExtension
        guard let match = base.firstMatch(of: #/^(.+)_\d+_[0-9A-Fa-f-]{36}$/#) else { return base }
        return String(match.1)
    }

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

/// 撮れなかったわけ（人が読む）
public struct CaptureFailure: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
