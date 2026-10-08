import AskHubKit
import Foundation

/// 担当リポジトリの作成・削除の依頼（`repo-request` の open な Issue）。形は新機能の依頼と同じ
public typealias RepositoryRequestIssue = IdeaRequestIssue

/// 作成・削除のコマンドの出力の読み取り（副作用なし）。
///
/// コマンドは人に伝える行を `ASKHUB_RESULT: …`（結果）と `ASKHUB_ERROR: …`（失敗の理由）で出す。
/// 依頼 Issue（public のこともある）にはこの行だけを書き、ほかの出力（ローカルのパスを含みうる）はログにだけ残す
public enum RepositoryCommandOutput {
    public static let resultPrefix = "ASKHUB_RESULT:"
    public static let errorPrefix = "ASKHUB_ERROR:"
    /// 前提を満たさず、やり直しても成功しない（未 push の変更がある・既に別のリポジトリがある など）ときの終了コード
    public static let preconditionFailedStatus: Int32 = 3

    public static func results(in output: String) -> [String] {
        lines(withPrefix: resultPrefix, in: output)
    }

    public static func errors(in output: String) -> [String] {
        lines(withPrefix: errorPrefix, in: output)
    }

    private static func lines(withPrefix prefix: String, in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: prefix) else {
                return nil
            }
            let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }
}

/// 作成・削除の依頼の処理の進み具合（副作用なし）
public struct RepositoryRequestTracker: Sendable, Equatable {
    /// コマンドを実行する試行の上限。前提を満たさない失敗はやり直さない
    public static let maxAttempts = 2

    public enum Phase: Sendable, Equatable {
        /// まだ処理できていない
        case pending(attempts: Int)
        /// 処理した。依頼 Issue への結果のコメントがまだ
        case succeeded(message: String)
        /// 結果をコメントした。依頼 Issue のクローズがまだ（コメントを重ねないよう分ける）
        case commented
        /// コメントとクローズを済ませた。検索に出なくなるまで覚えておく
        case completed
        /// 処理できなかった。依頼 Issue への失敗の通知がまだ
        case failing(reason: String)
        /// 失敗を通知した。人の対応を待つ（依頼し直すときは、新しい Issue を作る）
        case gaveUp
    }

    /// 依頼 Issue に残っている後処理
    public enum FollowUp: Sendable, Equatable {
        /// 結果をコメントし、クローズする
        case commentAndClose(message: String)
        /// クローズだけする
        case close
        /// 処理できなかったことをコメントする
        case reportFailure(reason: String)
    }

    /// キーは依頼 Issue の node id
    public private(set) var phases: [String: Phase] = [:]

    public init() {}

    /// 検索に出なくなった（クローズされた）依頼は追跡をやめる
    public mutating func prune(keeping issues: [RepositoryRequestIssue]) {
        let current = Set(issues.map(\.nodeID))
        phases = phases.filter { current.contains($0.key) }
    }

    public func followUps(in issues: [RepositoryRequestIssue]) -> [(RepositoryRequestIssue, FollowUp)] {
        issues.compactMap { issue in
            switch phases[issue.nodeID] {
            case let .succeeded(message):
                (issue, .commentAndClose(message: message))

            case .commented:
                (issue, .close)

            case let .failing(reason):
                (issue, .reportFailure(reason: reason))

            case nil, .pending, .completed, .gaveUp:
                nil
            }
        }
    }

    /// この周回で処理する依頼。担当リポジトリにある、信用する author のものを古い順に 1 件だけ。
    /// 返すリポジトリは依頼 Issue のある担当リポジトリ
    public func next(
        in issues: [RepositoryRequestIssue],
        config: OrchestratorConfig,
        trust: TrustDirectory? = nil
    ) -> (RepositoryRequestIssue, RepositoryConfig)? {
        let trust = trust ?? TrustDirectory(base: config.trustedAuthors)
        for issue in issues.sorted(by: { ($0.repository, $0.number) < ($1.repository, $1.number) }) {
            guard let repository = config.repository(named: issue.repository),
                  issue.isTrusted(by: trust.authors(for: issue.repository)) else {
                continue
            }
            switch phases[issue.nodeID] {
            case nil, .pending:
                return (issue, repository)

            case .succeeded, .commented, .completed, .failing, .gaveUp:
                continue
            }
        }
        return nil
    }

    public mutating func recordSucceeded(_ message: String, for issue: RepositoryRequestIssue) {
        phases[issue.nodeID] = .succeeded(message: message)
    }

    public mutating func recordCommented(_ issue: RepositoryRequestIssue) {
        phases[issue.nodeID] = .commented
    }

    public mutating func recordCompleted(_ issue: RepositoryRequestIssue) {
        phases[issue.nodeID] = .completed
    }

    /// やり直しても成功しない失敗。すぐに失敗の通知待ちにする
    public mutating func recordRejected(_ issue: RepositoryRequestIssue, reason: String) {
        phases[issue.nodeID] = .failing(reason: reason)
    }

    /// 処理できなかった。上限に達したら失敗の通知待ちにして `true` を返す
    @discardableResult
    public mutating func recordFailure(for issue: RepositoryRequestIssue, reason: String) -> Bool {
        var attempts = 1
        if case let .pending(previous) = phases[issue.nodeID] {
            attempts = previous + 1
        }
        if attempts >= Self.maxAttempts {
            phases[issue.nodeID] = .failing(reason: reason)
            return true
        }
        phases[issue.nodeID] = .pending(attempts: attempts)
        return false
    }

    public mutating func recordFailureReported(_ issue: RepositoryRequestIssue) {
        phases[issue.nodeID] = .gaveUp
    }
}
