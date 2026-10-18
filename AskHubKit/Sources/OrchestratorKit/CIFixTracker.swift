import AskHubKit
import Foundation

/// head のコミットで CI（GitHub Actions）が失敗し、すべての check run が終わった epic の最終 PR
public struct FailingPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    public let headBranch: String
    public let headSHA: String

    public init(repository: String, number: Int, headBranch: String, headSHA: String) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.headSHA = headSHA
    }

    /// PR を見分けるキー（リポジトリ名は小文字）
    var key: String {
        "\(repository.lowercased())#\(number)"
    }
}

/// 最終 PR の CI の失敗を直させた記録と、どのリポジトリで実行中か（副作用なし）。
///
/// 記録の正本は PR のコメントの目印（`ask-hub:ci-fix`）。直させる前に「試す」の目印をコメントしてから始めるので、
/// オーケストレーターを再起動しても同じ head のコミットでは試し直さない（PR ごとに、初めて見たときにコメントから読み直す）
public struct CIFixTracker: Sendable {
    /// 1 本の PR で直させるのはこの回数まで（head のコミットが変わるたびに 1 回）。超えたらあきらめる（人に任せる）
    public static let maxAttempts = 3

    public enum Outcome: Sendable, Equatable {
        /// 直して push した
        case fixed
        /// 試す前に head が進んでいた（試したことにしない）
        case stale
        /// 人の対応が要る
        case unresolved(reason: String)
    }

    /// 今から何をするか
    public enum Decision: Sendable, Equatable {
        /// 直させる
        case start
        /// 上限まで試したので、あきらめたことを伝える
        case giveUp
        /// 何もしない（この head では試した・あきらめた後）
        case skip
    }

    /// PR のコメントから読んだ（とその後に足した）記録
    struct History: Sendable, Equatable {
        /// 試した head のコミット（取り消したものを除く）
        var attemptedSHAs: [String] = []
        var gaveUp = false
    }

    private static let markerPrefix = "<!-- ask-hub:ci-fix "

    /// 直させる前のコメントに置く目印。この head のコミットで 1 回試したことを表す
    static func attemptMarker(_ sha: String) -> String {
        "\(markerPrefix)attempt \(sha) -->"
    }

    /// 利用上限・head の更新で試せなかったときに置く目印。同じ head の「試す」の目印を取り消す
    static func cancelMarker(_ sha: String) -> String {
        "\(markerPrefix)cancel \(sha) -->"
    }

    /// あきらめたときに置く目印
    static let gaveUpMarker = "\(markerPrefix)gave-up -->"

    private(set) var histories: [String: History] = [:]
    /// 直させているリポジトリ（名前の小文字）
    private(set) var runningRepositories: Set<String> = []

    public init() {}

    /// PR のコメントから記録を読み直す必要があるか（初めて見た・忘れた PR）
    public func needsHistory(of pullRequest: FailingPullRequest) -> Bool {
        histories[pullRequest.key] == nil
    }

    /// PR のコメント（古い順）から記録を読む。目印はオーケストレーターのコメント（`FinalPullRequestMarker.orchestrator` で始まるもの）だけから拾う
    public mutating func loadHistory(from comments: [IssueComment], for pullRequest: FailingPullRequest) {
        var history = History()
        for comment in comments where comment.body.hasPrefix(FinalPullRequestMarker.orchestrator) {
            for line in comment.body.split(whereSeparator: \.isNewline) where line.hasPrefix(Self.markerPrefix) {
                let words = line.dropFirst(Self.markerPrefix.count).split(separator: " ")
                switch (words.first, words.dropFirst().first) {
                case let ("attempt"?, sha?) where !history.attemptedSHAs.contains(String(sha)):
                    history.attemptedSHAs.append(String(sha))

                case let ("cancel"?, sha?):
                    history.attemptedSHAs.removeAll { $0 == sha }

                case ("gave-up"?, _):
                    history.gaveUp = true

                default:
                    break
                }
            }
        }
        histories[pullRequest.key] = history
    }

    /// 記録から、今回すること。記録を読んでいない PR は `skip`
    public func decision(for pullRequest: FailingPullRequest) -> Decision {
        guard let history = histories[pullRequest.key], !history.gaveUp,
              !history.attemptedSHAs.contains(pullRequest.headSHA) else {
            return .skip
        }
        return history.attemptedSHAs.count >= Self.maxAttempts ? .giveUp : .start
    }

    /// 直させ始めた。この head では試したことにし、終わるまで同じリポジトリのほかの PR は始めない
    public mutating func start(_ pullRequest: FailingPullRequest) {
        histories[pullRequest.key, default: History()].attemptedSHAs.append(pullRequest.headSHA)
        runningRepositories.insert(pullRequest.repository.lowercased())
    }

    /// 試したことを取り消す（利用上限で終わった・head が進んでいたなど）。次のポーリングで試し直す
    public mutating func cancel(_ pullRequest: FailingPullRequest) {
        histories[pullRequest.key]?.attemptedSHAs.removeAll { $0 == pullRequest.headSHA }
    }

    /// 直させ終わった（結果によらず呼ぶ）
    public mutating func finish(_ pullRequest: FailingPullRequest) {
        runningRepositories.remove(pullRequest.repository.lowercased())
    }

    /// あきらめた
    public mutating func giveUp(_ pullRequest: FailingPullRequest) {
        histories[pullRequest.key, default: History()].gaveUp = true
    }

    /// 上限まで試したか（この後に失敗しても、もう直させない）
    public func reachedLimit(_ pullRequest: FailingPullRequest) -> Bool {
        (histories[pullRequest.key]?.attemptedSHAs.count ?? 0) >= Self.maxAttempts
    }

    /// そのリポジトリで直させているか
    public func isRunning(in repository: String) -> Bool {
        runningRepositories.contains(repository.lowercased())
    }

    /// CI が失敗していない（一覧に出なくなった）PR の記録を忘れる。また失敗したら、コメントから読み直す
    public mutating func prune(keeping pullRequests: [FailingPullRequest]) {
        let current = Set(pullRequests.map(\.key))
        histories = histories.filter { current.contains($0.key) }
    }

    /// コマンドの出力の最後の `ASKHUB_RESULT:` の行から結果を読む
    public static func outcome(in output: String) -> Outcome? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ASKHUB_RESULT:") }) else {
            return nil
        }
        let value = line.dropFirst("ASKHUB_RESULT:".count).trimmingCharacters(in: .whitespaces)
        switch value {
        case "fixed":
            return .fixed

        case "stale":
            return .stale

        default:
            guard value.hasPrefix("unresolved") else {
                return nil
            }
            let reason = value.dropFirst("unresolved".count).trimmingCharacters(in: .whitespaces)
            return .unresolved(reason: reason.isEmpty ? "理由は出力されませんでした" : reason)
        }
    }
}
