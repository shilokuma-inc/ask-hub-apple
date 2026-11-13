import AskHubProtocol
import Foundation

// MARK: - リポジトリの保護と、加えるときの準備

extension StateSnapshotBuilder {
    /// `repo.json` の `protection` を画面の形にする。最後に送った保護の設定が断られていれば（その後に掛け直していなければ）、理由を添える
    func protection(of file: RepositoryFile) -> RepositoryProtection {
        let protection = file.protection
        let state: RepositoryProtection.State
        switch (protection.appliedAt, protection.drift) {
        case let (applied?, drift?):
            state = .drifted(appliedAt: applied.date, problems: drift.problems, foundAt: drift.foundAt.date)
        case let (applied?, nil):
            state = .applied(at: applied.date)
        case (nil, _):
            state = .notApplied
        }
        let defaultChecks = file.build?.childChecks ?? ProtectionPolicy.defaultRequiredChecks
        return RepositoryProtection(
            state: state,
            requiredChecks: protection.requiredChecks ?? defaultChecks,
            replaced: (protection.replaced ?? []).map(Self.label),
            remaining: (protection.remaining ?? []).map(Self.label),
            rejection: rejection(of: ApplyProtectionIntent.kind, repo: file.repo, after: protection.appliedAt)
        )
    }

    /// `repo.json` の `setup` を画面の形にする。まだ流していなければ nil
    func setup(of file: RepositoryFile) -> RepositorySetupStatus? {
        guard let setup = file.setup else {
            return nil
        }
        let pullRequest = setup.workflows.flatMap { workflows -> SetupPullRequest? in
            guard let number = workflows.pullRequest, let head = workflows.head else {
                return nil
            }
            let state: SetupPullRequest.State = switch workflows.state {
            case .merged: .merged
            case .closed: .closed
            case .open, .notNeeded: .open
            }
            return .init(number: number, head: head, state: state, changes: workflows.changes.map(Self.label))
        }
        let discussions: RepositorySetupStatus.Discussions? = setup.discussions.map { state in
            switch state {
            case .ready: .ready
            case .missingCategory: .missingCategory
            case .unknown: .unknown
            }
        }
        return RepositorySetupStatus(
            updatedAt: setup.updatedAt.date,
            discussions: discussions,
            workflowPullRequest: pullRequest,
            workflowsChecked: setup.workflows != nil,
            problems: setup.problems ?? [],
            approvalRejection: rejection(of: ApproveSetupPullRequestIntent.kind, repo: file.repo, after: nil)
        )
    }

    /// このリポジトリに送った、その種類の最後の意図が断られた理由。`after` より後に送ったものだけを見る（掛け直した後の古い理由を出さない）
    private func rejection(of kind: String, repo: RepositoryFullName, after: Timestamp?) -> String? {
        guard let last = documents.sentIntents.first(where: { $0.envelope.kind == kind && $0.envelope.repo == repo }),
              last.consumed?.result == .rejected else {
            return nil
        }
        if let after, last.envelope.issuedAt.date <= after.date {
            return nil
        }
        return last.consumed?.reason ?? "理由は書かれていません"
    }

    private static func label(_ existing: ExistingProtection) -> String {
        switch existing.kind {
        case .classic: "クラシックの保護 \(existing.name)"
        case .ruleset: "ルールセット \(existing.name)"
        case .organizationRuleset: "organization のルールセット \(existing.name)"
        }
    }

    private static func label(_ change: WorkflowChange) -> String {
        let name = change.path.split(separator: "/").last.map(String.init) ?? change.path
        return switch change.kind {
        case .removeLegacy: "\(name) を外す"
        case .removePathFilters: "\(name) の paths を外す"
        }
    }
}
