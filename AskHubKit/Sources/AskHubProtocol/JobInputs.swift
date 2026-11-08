import Foundation

/// 段階 3 のジョブの入力（ジョブの `input`。`docs/renewal/protocol.md` の表）。
///
/// 司令塔がジョブを作るときに書き、ワーカーが引き受けるときに読む。形が違う入力のジョブは動かさない（`JobFile.input(as:)` が nil）
public protocol JobInput: Codable, Equatable, Sendable {
    /// 型だけでは表せない決まりに合うか
    var isValid: Bool { get }
}

/// 子 PR・最終 PR と、見た head のコミット（`reviewTask`・`fixFinalPullRequest`・`mergeFinalPullRequest`）。
/// head を固定して、見た後に push された変更でマージ・直しをしないようにする
public struct PullRequestInput: JobInput {
    public var pullRequest: Int
    public var head: String

    public init(pullRequest: Int, head: String) {
        self.pullRequest = pullRequest
        self.head = head
    }

    public var isValid: Bool { pullRequest >= 1 && AttemptFile.isCommitSHA(head) }
}

/// タスクの直し（`fixTask`）
public struct FixTaskInput: JobInput {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// CI の失敗
        case ci
        /// レビュー役の必須の指摘
        case review
        /// 人の判断のカードの「直してほしい」「別案にする」と、最終 PR への指示（`instructFinal`）。元の人の意図はジョブの `origin`
        case human
        /// 最終 PR が base とコンフリクトしている。base を作業ブランチに取り込み、コンフリクトを解消する（最終 PR）
        case conflict
    }

    public var pullRequest: Int
    public var head: String
    public var reason: Reason

    public init(pullRequest: Int, head: String, reason: Reason) {
        self.pullRequest = pullRequest
        self.head = head
        self.reason = reason
    }

    public var isValid: Bool { PullRequestInput(pullRequest: pullRequest, head: head).isValid }
}

/// 落ちたジョブの流し直し（`rerunChecks`）。コードに触れない
public struct RerunChecksInput: JobInput {
    public var pullRequest: Int
    public var head: String
    /// 流し直す Actions の run の id
    public var runs: [Int64]

    public init(pullRequest: Int, head: String, runs: [Int64]) {
        self.pullRequest = pullRequest
        self.head = head
        self.runs = runs
    }

    public var isValid: Bool {
        PullRequestInput(pullRequest: pullRequest, head: head).isValid && !runs.isEmpty && runs.allSatisfy { $0 >= 1 }
    }
}

/// base の取り込み（`integrateDevelop`）
public struct IntegrateBaseInput: JobInput {
    /// 取り込む base のコミット
    public var base: String

    public init(base: String) {
        self.base = base
    }

    public var isValid: Bool { AttemptFile.isCommitSHA(base) }
}

extension JobFile {
    /// 入力を型で読む。無い・形が違う・決まりに合わないときは nil
    public func input<Input: JobInput>(as type: Input.Type) -> Input? {
        guard let input else { return nil }
        guard let decoded = try? JSONDecoder().decode(Input.self, from: CanonicalJSON.data(for: .object(input))),
              decoded.isValid else {
            return nil
        }
        return decoded
    }
}

extension JobInput {
    /// ジョブの `input` に書く形
    public var jobInput: [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(self), case let .object(fields)? = try? JSONValue(parsing: data) else { return [:] }
        return fields
    }
}
