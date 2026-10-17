import Foundation

/// 手動ループ（`manual-loop`）の 1 つ。最終 PR への指示を探す手がかり
public struct ManualLoopTarget: Sendable, Equatable, Hashable {
    /// `owner/repo`
    public var repository: String
    /// ゴール元の Discussion の番号
    public var discussion: Int
    /// 担当者が書いた状態の epic ブランチ（まだ書いていなければ `nil`）
    public var epic: String?

    public init(repository: String, discussion: Int, epic: String?) {
        self.repository = repository
        self.discussion = discussion
        self.epic = epic
    }

    /// `owner/repo#番号` の小文字（`ManualLoopItem.items` の `pendingFinalInstructions` のキー）
    public var key: String {
        Self.key(repository: repository, discussion: discussion)
    }

    public static func key(repository: String, discussion: Int) -> String {
        "\(repository)#\(discussion)".lowercased()
    }
}

/// 最終 PR（`epic-final`）の本文の先頭にある、ゴール元の Discussion の目印（`docs/protocol.md` の「ゴール元の Discussion の目印」）
public enum GoalDiscussionMarker {
    /// 本文の先頭の数行にある `<!-- ask-hub:discussion N -->` の N。無ければ `nil`
    public static func discussion(in body: String) -> Int? {
        // `\r\n` は 1 文字として扱われるので、改行の文字で区切る
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(3)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.wholeMatch(of: pattern), let number = Int(match.output.1) {
                return number
            }
        }
        return nil
    }

    /// `Regex` は `Sendable` ではないので computed property にする
    private static var pattern: Regex<(Substring, Substring)> {
        /<!-- ask-hub:discussion (\d+) -->/
    }
}

/// 手動ループの epic の最終 PR に、信用する author の未処理の指示があるかを確かめる。テストでは差し替える
public protocol ManualLoopFinalInstructionsChecking: Sendable {
    /// `loops` のうち、最終 PR に未処理の指示があるもの（`ManualLoopTarget.key`）
    func loopsWithUnprocessedInstructions(_ loops: [ManualLoopTarget]) async throws -> Set<String>
}

/// GitHub の REST API で、手動ループの epic の最終 PR と、そのコメントを読む。
/// 最終 PR は、同じリポジトリの、信用する author が作った open な `epic-final` の PR のうち、本文のゴール元の Discussion の目印が
/// その手動ループの Discussion のもの（無ければ head のブランチが状態の epic のもの）。
/// 一覧もコメントもページングを最後まで追う。レート制限は `GitHubClient` が待って再試行する
public struct GitHubManualLoopFinalInstructions: ManualLoopFinalInstructionsChecking {
    private let client: GitHubClient
    private let trustedAuthors: any TrustedAuthorsResolving

    public init(client: GitHubClient, trustedAuthors: any TrustedAuthorsResolving = TrustedAuthors.default) {
        self.client = client
        self.trustedAuthors = trustedAuthors
    }

    public func loopsWithUnprocessedInstructions(_ loops: [ManualLoopTarget]) async throws -> Set<String> {
        var result = Set<String>()
        let repositories = Dictionary(grouping: loops) { $0.repository.lowercased() }
        for (_, targets) in repositories.sorted(by: { $0.key < $1.key }) {
            guard let repository = targets.first?.repository else {
                continue
            }
            // 1 つのリポジトリで読めなくても、ほかのリポジトリの促しは出す。
            // レート制限（待っても戻らなかったもの）と打ち切りは、ほかのリポジトリも同じなので、そこで止める
            do {
                result.formUnion(try await pending(targets, in: repository))
            } catch let error as GitHubError {
                if case .rateLimited = error {
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return result
    }

    /// 1 つのリポジトリの手動ループのうち、最終 PR に未処理の指示があるもの
    private func pending(_ targets: [ManualLoopTarget], in repository: String) async throws -> Set<String> {
        let trusted = await trustedAuthors.trustedAuthors(for: repository)
        let pulls = try await finalPullRequests(in: repository, trustedAuthors: trusted)
        var result = Set<String>()
        for target in targets {
            guard let pull = Self.finalPullRequest(of: target, in: pulls) else {
                continue
            }
            let comments = try await comments(in: repository, number: pull.number)
            if !FinalPullRequestHistory.unprocessedInstructions(in: comments, trustedAuthors: trusted).isEmpty {
                result.insert(target.key)
            }
        }
        return result
    }

    /// 手動ループの最終 PR。ゴール元の Discussion の目印を優先し、目印の無い PR だけを head のブランチで見る
    static func finalPullRequest(of target: ManualLoopTarget, in pulls: [FinalPullRequestSummary]) -> FinalPullRequestSummary? {
        if let marked = pulls.first(where: { GoalDiscussionMarker.discussion(in: $0.body ?? "") == target.discussion }) {
            return marked
        }
        guard let epic = target.epic else {
            return nil
        }
        return pulls.first { GoalDiscussionMarker.discussion(in: $0.body ?? "") == nil && $0.head.ref == epic }
    }

    private func finalPullRequests(in repository: String, trustedAuthors: TrustedAuthors) async throws -> [FinalPullRequestSummary] {
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [URLQueryItem(name: "state", value: "open")],
            of: FinalPullRequestSummary.self
        )
        // ラベルは書き込み権限があれば誰でも付けられるので、信用する author が作った最終 PR だけを見る
        return pulls.filter { pull in
            pull.labels.contains { $0.name == AskHubLabel.epicFinal.rawValue } && trustedAuthors.contains(pull.user?.login)
        }
    }

    /// PR のコメント（Issue コメント）を作成順（同時刻は id 順）に返す。処理済みの判定は並び順に依存するため
    private func comments(in repository: String, number: Int) async throws -> [IssueComment] {
        let comments = try await client.getAllPages(
            "repos/\(repository)/issues/\(number)/comments",
            of: FinalPullRequestCommentSummary.self
        )
        return comments
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            .map { IssueComment(id: $0.id, author: $0.user?.login, body: $0.body ?? "", createdAt: $0.createdAt) }
    }
}

/// REST の PR の一覧の 1 件（最終 PR を探すのに使う分だけ）
struct FinalPullRequestSummary: Decodable, Equatable {
    struct Ref: Decodable, Equatable {
        let ref: String
    }

    struct User: Decodable, Equatable {
        let login: String
    }

    struct Label: Decodable, Equatable {
        let name: String
    }

    let number: Int
    let body: String?
    let head: Ref
    /// 削除済みのユーザーでは `nil`
    let user: User?
    let labels: [Label]
}

/// REST の Issue コメントの 1 件
private struct FinalPullRequestCommentSummary: Decodable {
    struct User: Decodable {
        let login: String
    }

    let id: Int
    let user: User?
    let body: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
    }
}
