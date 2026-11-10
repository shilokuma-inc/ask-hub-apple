import AskHubCommands
import AskHubProtocol
import Foundation

/// 用意した行き先（Simulator は `SimulatorPool.prepare` で起動したもの）
public enum PreparedDestination: Equatable, Hashable, Sendable {
    case simulator(Simulator)
    case macOS
}

/// 1 回のビルドかテストの依頼
public struct BuildRequest: Equatable, Sendable {
    public var settings: BuildSettings
    public var kind: BuildKind
    public var destination: PreparedDestination
    /// ビルドする写し（epic の worktree）
    public var sourceDirectory: URL
    /// DerivedData と結果のバンドルを分ける単位
    public var epic: ULID

    public init(settings: BuildSettings, kind: BuildKind, destination: PreparedDestination, sourceDirectory: URL, epic: ULID) {
        self.settings = settings
        self.kind = kind
        self.destination = destination
        self.sourceDirectory = sourceDirectory
        self.epic = epic
    }
}

/// `xcodebuild` を決まった形で流し、結果のバンドルから要約と失敗の区分を作る。
///
/// - DerivedData と結果のバンドルは epic ごと（`BuildDirectories`）。結果のバンドルは、操作と行き先ごとに最新の 1 つだけを残す
/// - 行き先は `-destination id=<UDID>`（Simulator）か `platform=macOS`。macOS はアドホック署名にする（署名用の証明書が無い Mac でも通るように）
/// - 設定にプロジェクトを作る道具（`BuildSettings.generate`）があれば、`xcodebuild` の前に流して作り直す（`ProjectGeneration`）
/// - 環境変数は `BuildTools.environment` で作り直す。時間の上限を超えたら、子孫のプロセスまで止める（`CommandRunning`）
public struct XcodeBuildRunner: Sendable {
    public var tools: BuildTools
    public var directories: BuildDirectories
    public var runner: any CommandRunning
    /// `xcresulttool` の 1 回の上限
    public var readTimeout: Duration
    /// プロジェクトを作る道具の 1 回の上限
    public var generateTimeout: Duration

    public init(
        tools: BuildTools,
        directories: BuildDirectories,
        runner: any CommandRunning,
        readTimeout: Duration = .seconds(2 * 60),
        generateTimeout: Duration = .seconds(5 * 60)
    ) {
        self.tools = tools
        self.directories = directories
        self.runner = runner
        self.readTimeout = readTimeout
        self.generateTimeout = generateTimeout
    }

    /// 流して結果を返す。失敗も結果として返し、投げるのは取り消されたときだけ
    public func run(_ request: BuildRequest, timeout: Duration) async throws(CancellationError) -> BuildOutcome {
        let derivedData = directories.derivedData(for: request.epic)
        let bundle = directories.resultBundle(for: request.epic, named: Self.bundleName(for: request))
        do {
            try directories.prepareResultBundle(at: bundle)
        } catch {
            return BuildOutcome(failure: .environment, summary: error.description)
        }
        let cleaner = ReportCleaner(sourceDirectory: request.sourceDirectory, home: tools.home)
        if let generator = request.settings.generate {
            let generation = ProjectGeneration(tools: tools, runner: runner, timeout: min(timeout, generateTimeout))
            if case let .failure(failure) = try await generation.run(request.settings, in: request.sourceDirectory) {
                return failure.outcome(of: generator, cleaner: cleaner)
            }
        }
        let arguments = Self.arguments(for: request, derivedData: derivedData, resultBundle: bundle)
        let result: CommandResult
        do {
            result = try await runner.run(tools.command(arguments, in: request.sourceDirectory, timeout: timeout))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return BuildOutcome(failure: .environment, summary: "xcodebuild を起動できない（\(error.localizedDescription)）")
        }
        let contents = await ResultBundleReader(tools: tools, runner: runner, timeout: readTimeout).read(bundle, tests: request.kind.isTest)
        if Task.isCancelled { throw CancellationError() }
        var report = cleaner.report(from: contents)
        let failure = BuildClassifier.classify(result, kind: request.kind, report: report)
        // エラーや落ちたテストで理由が分からない失敗には、出力の抜粋を付ける
        if let failure, ![.build, .test].contains(failure) || report.errors.isEmpty && report.failedTests.isEmpty {
            report.log = cleaner.logExcerpt(of: result.outputText)
        }
        let summary = cleaner.clean(BuildClassifier.summary(failure, kind: request.kind, report: report, result: result))
        let exists = FileManager.default.fileExists(atPath: bundle.path)
        return BuildOutcome(failure: failure, summary: summary, report: report, resultBundle: exists ? bundle : nil)
    }

    /// 結果のバンドルの名前（`testLight-askhub-worker-1-iPhone-17-Pro-iOS-26.5` など）
    static func bundleName(for request: BuildRequest) -> String {
        let destination = switch request.destination {
        case .simulator(let simulator): SimulatorPool.slug(simulator.name)
        case .macOS: "macOS"
        }
        return "\(request.kind.rawValue)-\(destination)"
    }

    /// `xcrun` に渡す引数（`xcodebuild …`）
    static func arguments(for request: BuildRequest, derivedData: URL, resultBundle: URL) -> [String] {
        let settings = request.settings
        var arguments = ["xcodebuild", request.kind.isTest ? "test" : "build"]
        let destination = switch request.destination {
        case .simulator(let simulator): "id=\(simulator.udid)"
        case .macOS: "platform=macOS"
        }
        arguments += [
            settings.projectOption, settings.project,
            "-scheme", settings.scheme,
            "-destination", destination,
            "-derivedDataPath", derivedData.path,
            "-resultBundlePath", resultBundle.path,
            // 新しい DerivedData では、パッケージのプラグインとマクロの信頼を確かめる画面で止まるため
            "-skipPackagePluginValidation", "-skipMacroValidation"
        ]
        if let tests = settings.tests(for: request.kind) {
            // 並列のテストは Simulator の複製を作って場所を取り、遅くもなるので使わない
            arguments += ["-parallel-testing-enabled", "NO"]
            if let plan = tests.testPlan {
                arguments += ["-testPlan", plan]
            }
            arguments += tests.onlyTesting.map { "-only-testing:\($0)" }
            arguments += tests.skipTesting.map { "-skip-testing:\($0)" }
        }
        // 索引はワーカーでは使わない（場所と時間の節約）
        arguments.append("COMPILER_INDEX_STORE_ENABLE=NO")
        if request.destination == .macOS {
            arguments += ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER="]
        }
        return arguments
    }
}
