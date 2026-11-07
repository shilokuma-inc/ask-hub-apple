import AskHubCommands
import AskHubProtocol
import Foundation

/// ビルドとテストの失敗の区分
public enum BuildFailureKind: String, Codable, Sendable, CaseIterable {
    /// ビルドが通らない（コンパイル・リンクのエラー）。Claude に直させる
    case build
    /// テストが落ちた。Claude に直させる
    case test
    /// 実行時間の上限を超えた
    case timeout
    /// Simulator や Xcode の不調（起動できない・つながらない・行き先が見つからない・依存を取りに行けない）。
    /// コードの誤りではないので Claude に直させない
    case environment
    /// 上のどれでもない（設定の誤りなど）
    case unknown

    /// 試行の失敗の区分（`docs/renewal/architecture.md` の「失敗の区分と既定の扱い」）。
    /// 環境の不調は、Claude に直させても直らないので、ログの抜粋つきで人に渡す（想定外）
    public var failureClass: FailureClass {
        switch self {
        case .build: .buildFailed
        case .test: .testFailed
        case .timeout: .timeout
        case .environment, .unknown: .unexpected
        }
    }
}

/// ビルドかテストを 1 回流した結果
public struct BuildOutcome: Equatable, Sendable {
    /// 失敗の区分。通ったら nil
    public var failure: BuildFailureKind?
    /// 短い説明（試行の記録とクライアントに出す）
    public var summary: String
    public var report: BuildReport
    /// 結果のバンドル。作られなかったら nil
    public var resultBundle: URL?

    public init(failure: BuildFailureKind?, summary: String, report: BuildReport = BuildReport(), resultBundle: URL? = nil) {
        self.failure = failure
        self.summary = summary
        self.report = report
        self.resultBundle = resultBundle
    }

    public var succeeded: Bool { failure == nil }

    /// 試行の失敗として書く形。通ったら nil
    public var attemptFailure: AttemptFailure? {
        guard let failure else { return nil }
        let excerpt = report.text(limit: Redaction.maximumExcerpt)
        return AttemptFailure(failureClass: failure.failureClass, message: summary, logExcerpt: excerpt.isEmpty ? nil : excerpt)
    }
}

/// `xcodebuild` の結果を区分に分ける
enum BuildClassifier {
    static func classify(_ result: CommandResult, kind: BuildKind, report: BuildReport) -> BuildFailureKind? {
        if result.timedOut { return .timeout }
        if result.succeeded { return nil }
        let output = result.outputText
        let texts = [output] + report.errors.map(\.message) + report.failedTests.map(\.message)
        let lowered = texts.joined(separator: "\n").lowercased()
        if environmentPhrases.contains(where: lowered.contains) { return .environment }
        if !report.errors.isEmpty { return .build }
        if kind.isTest, !report.failedTests.isEmpty || (report.tests?.failed ?? 0) > 0 { return .test }
        // 結果のバンドルから読めなかったときは、出力で見分ける
        if output.contains(#/\.(swift|m|mm|c|cc|cpp|h|metal):[0-9]+:[0-9]+: error: /#) || output.contains("linker command failed") {
            return .build
        }
        if kind.isTest, output.contains("** TEST FAILED **") { return .test }
        if output.contains("** BUILD FAILED **") { return .build }
        return .unknown
    }

    /// Simulator や Xcode の不調を示す文（小文字）
    static let environmentPhrases = [
        "unable to find a device matching the provided destination",
        "unable to find a destination matching the provided destination",
        "unable to boot",
        "failed to boot",
        // 開発者モードが無効な Mac で、launchd から Simulator のテストを流したとき（LEARNINGS.md）
        "failed to bless service hub",
        "** build interrupted **",
        "test runner never began executing tests",
        "the test runner hung",
        "lost connection to the test manager service",
        "failed to install or launch the test runner",
        "coresimulatorservice",
        "could not resolve host",
        "the internet connection appears to be offline"
    ]

    /// 結果の短い説明
    static func summary(_ failure: BuildFailureKind?, kind: BuildKind, report: BuildReport, result: CommandResult) -> String {
        let total = report.tests.map { "全 \($0.total) 件" }
        switch failure {
        case nil:
            if kind.isTest { return "テストが通った" + (total.map { "（\($0)）" } ?? "") }
            return "ビルドが通った"
        case .build:
            return "ビルドが通らない" + (report.errors.isEmpty ? "" : "（エラー \(report.errors.count) 件）")
        case .test:
            let failed = report.failedTests.isEmpty ? report.tests?.failed : report.failedTests.count
            return "テストが落ちた" + (failed.map { "（\($0) 件" + (total.map { " / \($0)" } ?? "") + "）" } ?? "")
        case .timeout:
            return "ビルドとテストが時間の上限を超えた"
        case .environment:
            return "Simulator か Xcode の不調でビルドとテストを流せない"
        case .unknown:
            let line = result.outputText.split(whereSeparator: \.isNewline).first { $0.contains("xcodebuild: error:") }
            return "xcodebuild が失敗した（終了コード \(result.status)）" + (line.map { ": " + BuildReport.truncate(String($0), limit: 200) } ?? "")
        }
    }
}
