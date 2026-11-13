import Foundation

/// 対象のリポジトリのブランチの保護（ルールセット `askhub-protect`）の様子（`repo.json` の `protection`）。
/// 人が「保護の設定」を押すと、司令塔が管理用のトークンで掛ける（`docs/renewal/operations.md` の「保護の設定」）
struct RepositoryProtection: Hashable {
    enum State: Hashable {
        /// まだ掛けていない
        case notApplied
        /// 掛けた。ずれていない
        case applied(at: Date)
        /// 掛けた後に、外された・変わった（直すには押し直す）
        case drifted(appliedAt: Date, problems: [String], foundAt: Date)
    }

    var state: State
    /// 必須のチェック。掛けていれば掛けたもの、まだならビルドの設定の `childChecks`（無ければ `build / build`）。押す画面の既定にする
    var requiredChecks: [String]
    /// 掛けたときに外した保護（例: クラシックの保護 develop）
    var replaced: [String] = []
    /// 外せずに残った保護（organization のルールセット）
    var remaining: [String] = []
    /// 最後に送った保護の設定を、司令塔が断った理由。無ければ nil
    var rejection: String?

    /// 守るブランチ（`ProtectionPolicy.branches`）
    static let branches = ["develop", "main", "release/**"]
}

/// 対象に加えるときの GitHub 側の準備の様子（`repo.json` の `setup`。`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）
struct RepositorySetupStatus: Hashable {
    enum Discussions: Hashable {
        case ready
        /// カテゴリ「Ideas」が無い（人が GitHub の画面で作る）
        case missingCategory
        /// 有効にできない・確かめられない
        case unknown
    }

    var updatedAt: Date
    var discussions: Discussions?
    /// 直すところが無ければ nil（`workflowsChecked` が true）
    var workflowPullRequest: SetupPullRequest?
    /// ワークフローを確かめられたか（直すところが無い・PR を出した）
    var workflowsChecked: Bool
    /// 準備を止めた・できなかった理由（管理用のトークンが無い など）
    var problems: [String] = []
    /// 最後に送った準備の PR の承認を、司令塔が断った理由。無ければ nil
    var approvalRejection: String?
}

/// 対象に加えるときに、ワークフローを直すため司令塔が出した PR
struct SetupPullRequest: Hashable {
    enum State: Hashable {
        case open
        case merged
        case closed
    }

    var number: Int
    /// 出したときの head。承認はこれに結びつける
    var head: String
    var state: State
    /// 直したところ（例: build.yml の paths を外す）
    var changes: [String]
}

extension TargetRepository {
    /// GitHub のリポジトリの Discussions のカテゴリの画面
    var discussionCategoriesURL: URL? {
        URL(string: "https://github.com/\(fullName)/discussions/categories")
    }
}

// MARK: - あなたの番

extension InboxBuilder {
    /// 保護のずれと、加えるときの準備で人がすること（時間のあるときに）
    static func administrationItems(_ repository: TargetRepository) -> [InboxItem] {
        var items: [InboxItem] = []
        if case let .drifted(_, problems, foundAt) = repository.protection?.state {
            let detail = problems.joined(separator: "・")
            items.append(item(repository, id: "protection", title: "保護のずれを直す", detail: detail, since: foundAt))
        }
        guard let setup = repository.setup else {
            return items
        }
        if !setup.problems.isEmpty {
            let detail = setup.problems.joined(separator: "・")
            items.append(item(repository, id: "setup", title: "準備をやり直す", detail: detail, since: setup.updatedAt))
        }
        if setup.discussions == .missingCategory {
            let detail = "Discussions にカテゴリ「Ideas」が無いので、GitHub の画面で作る"
            items.append(item(repository, id: "ideas", title: "Discussions のカテゴリを作る", detail: detail, since: setup.updatedAt))
        }
        if let pullRequest = setup.workflowPullRequest, pullRequest.state == .open {
            let detail = "PR #\(pullRequest.number) · \(pullRequest.changes.joined(separator: "・"))"
            items.append(item(repository, id: "workflows", title: "ワークフローの直しを承認する", detail: detail, since: setup.updatedAt))
        }
        return items
    }

    private static func item(_ repository: TargetRepository, id: String, title: String, detail: String, since: Date) -> InboxItem {
        InboxItem(
            id: "repository/\(repository.id)/\(id)",
            urgency: .whenFree,
            kind: .repositorySetup,
            repositoryID: repository.id,
            title: title,
            context: repository.appName,
            detail: detail,
            since: since,
            route: .repository(repository.id),
            targets: [.repository(repository.id)]
        )
    }
}
