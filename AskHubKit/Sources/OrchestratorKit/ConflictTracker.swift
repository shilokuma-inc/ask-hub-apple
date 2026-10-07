import Foundation

/// develop とコンフリクトした epic の最終 PR
public struct ConflictingPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    public let headBranch: String
    public let baseBranch: String
    public let headSHA: String
    public let baseSHA: String

    public init(repository: String, number: Int, headBranch: String, baseBranch: String, headSHA: String, baseSHA: String) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.headSHA = headSHA
        self.baseSHA = baseSHA
    }

    /// PR を見分けるキー（リポジトリ名は小文字）
    var key: String {
        "\(repository.lowercased())#\(number)"
    }

    /// 取り込みを試す組み合わせ（epic と develop のコミット）。同じ組み合わせでは 1 回しか試さない
    var attemptKey: String {
        "\(headSHA)...\(baseSHA)"
    }
}

/// 最終 PR のコンフリクトの解消をどこまで試したかを覚える（副作用なし）
public struct ConflictTracker: Sendable {
    /// 解消できなかったのがこの回数続いたら、その PR はあきらめる（人に任せる）
    public static let maxFailures = 3

    public enum Outcome: Sendable, Equatable {
        /// 取り込めた（コンフリクトなし / 解消した）
        case merged
        case resolved
        /// 人の対応が要る
        case unresolved(reason: String)
    }

    struct Entry: Sendable {
        var triedAttempts: Set<String> = []
        var failures = 0
        var gaveUp = false
    }

    private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// 次に試す PR。担当リポジトリのもので、あきらめておらず、まだ試していない組み合わせのもの
    public func next(in pullRequests: [ConflictingPullRequest], config: OrchestratorConfig) -> (ConflictingPullRequest, RepositoryConfig)? {
        for pullRequest in pullRequests {
            guard let repository = config.repository(named: pullRequest.repository) else {
                continue
            }
            let entry = entries[pullRequest.key] ?? Entry()
            if entry.gaveUp || entry.triedAttempts.contains(pullRequest.attemptKey) {
                continue
            }
            return (pullRequest, repository)
        }
        return nil
    }

    /// 結果を記録する。あきらめることになったら `true`
    @discardableResult
    public mutating func record(_ outcome: Outcome, for pullRequest: ConflictingPullRequest) -> Bool {
        var entry = entries[pullRequest.key] ?? Entry()
        entry.triedAttempts.insert(pullRequest.attemptKey)
        switch outcome {
        case .merged, .resolved:
            entry.failures = 0

        case .unresolved:
            entry.failures += 1
            entry.gaveUp = entry.failures >= Self.maxFailures
        }
        entries[pullRequest.key] = entry
        return entry.gaveUp
    }

    /// コンフリクトしていない（検索に出なくなった）PR を忘れる
    public mutating func prune(keeping pullRequests: [ConflictingPullRequest]) {
        let current = Set(pullRequests.map(\.key))
        entries = entries.filter { current.contains($0.key) }
    }

    /// コマンドの出力の最後の `ASKHUB_RESULT:` の行から結果を読む
    public static func outcome(in output: String) -> Outcome? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ASKHUB_RESULT:") }) else {
            return nil
        }
        let value = line.dropFirst("ASKHUB_RESULT:".count).trimmingCharacters(in: .whitespaces)
        switch value {
        case "merged":
            return .merged

        case "resolved":
            return .resolved

        default:
            guard value.hasPrefix("unresolved") else {
                return nil
            }
            let reason = value.dropFirst("unresolved".count).trimmingCharacters(in: .whitespaces)
            return .unresolved(reason: reason.isEmpty ? "理由は出力されませんでした" : reason)
        }
    }
}
