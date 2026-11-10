import AskHubCommands
import AskHubProtocol
import Foundation

extension ProjectGenerator {
    /// 実行ファイルの名前（`BuildTools.toolDirectories` から探す）
    var program: String {
        switch self {
        case .xcodegen: "xcodegen"
        }
    }

    /// 作業場所の直下で流す引数
    var arguments: [String] {
        switch self {
        case .xcodegen: ["generate"]
        }
    }
}

/// ビルドの前に、設定の道具でプロジェクトを作る（`BuildSettings.generate`。`.xcodeproj` をコミットしないリポジトリ）。
///
/// ビルドのたびに作り直す（Claude がファイルや `project.yml` を変えても、プロジェクトに入るように）。
/// `xcodebuild` と同じく、作業場所の直下で、作り直した環境変数（`BuildTools.environment`）で流す
struct ProjectGeneration {
    /// 作れなかったわけ
    enum Failure: Error, Equatable {
        /// 道具が無い・起動できない（この Mac の準備が足りない）
        case unavailable(String)
        /// 時間内に終わらない
        case timedOut
        /// 道具が失敗した（`project.yml` の誤りなど）。`output` は道具の出力
        case failed(status: Int32, output: String)
    }

    var tools: BuildTools
    var runner: any CommandRunning
    var timeout: Duration

    /// 作る。作らない設定なら何もしない。失敗も結果として返し、投げるのは取り消されたときだけ
    func run(_ settings: BuildSettings, in directory: URL) async throws(CancellationError) -> Result<Void, Failure> {
        guard let generator = settings.generate else { return .success(()) }
        guard let executable = tools.tool(named: generator.program) else {
            let places = tools.toolDirectories.map(\.path).joined(separator: "・")
            return .failure(.unavailable("\(generator.program) が見つからない（\(places) に入れる）"))
        }
        let result: CommandResult
        do {
            result = try await runner.run(tools.command(executable, generator.arguments, in: directory, timeout: timeout))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.unavailable("\(generator.program) を起動できない（\(error.localizedDescription)）"))
        }
        if Task.isCancelled { throw CancellationError() }
        if result.timedOut { return .failure(.timedOut) }
        guard result.succeeded else { return .failure(.failed(status: result.status, output: result.outputText)) }
        return .success(())
    }

    /// 人と Claude に見せるコマンド（`xcodegen generate`）
    static func label(of generator: ProjectGenerator) -> String {
        ([generator.program] + generator.arguments).joined(separator: " ")
    }
}

extension ProjectGeneration.Failure {
    /// 人と Claude に見せる短い説明
    func summary(of generator: ProjectGenerator) -> String {
        let command = ProjectGeneration.label(of: generator)
        return switch self {
        case .unavailable(let reason): "プロジェクトを作れない（\(reason)）"
        case .timedOut: "プロジェクトを作る \(command) が時間の上限を超えた"
        case .failed(let status, _): "プロジェクトを作れない（\(command) の終了コード \(status)）"
        }
    }

    /// ビルドとテストの結果として返す形。道具の失敗は設定のファイルの誤りとして Claude に直させ、道具が無いのは環境の不調にする
    func outcome(of generator: ProjectGenerator, cleaner: ReportCleaner) -> BuildOutcome {
        let summary = cleaner.clean(summary(of: generator))
        return switch self {
        case .unavailable: BuildOutcome(failure: .environment, summary: summary)
        case .timedOut: BuildOutcome(failure: .timeout, summary: summary)
        case .failed(_, let output):
            // XcodeGen は理由を `error` の行の次に書くので、エラーの行だけを選ばずに末尾を渡す
            BuildOutcome(
                failure: .build, summary: summary, report: BuildReport(log: cleaner.logExcerpt(of: output, preferringErrors: false))
            )
        }
    }
}
