import AskHubKit
import Foundation

// デモモードの取得元。DEBUG の UI テストで `-AskHubSampleChanges` を付けたときだけ、更新のたびに中身を変える取得元にする
// （リリースのビルドでは、今までどおり決まった中身を返す）

extension SampleLoopStatusSource {
    nonisolated static func launchDefault() -> any LoopStatusSource {
        #if DEBUG
        if SampleChanges.isEnabled {
            return ChangingSampleLoopStatusSource()
        }
        #endif
        return SampleLoopStatusSource()
    }
}

extension SampleInboxSource {
    nonisolated static func launchDefault() -> any InboxSource {
        #if DEBUG
        if SampleChanges.isEnabled {
            return ChangingSampleInboxSource()
        }
        #endif
        return SampleInboxSource()
    }
}

extension SampleMergeQueue {
    nonisolated static func launchDefault() -> any MergeQueueProviding {
        #if DEBUG
        if SampleChanges.isEnabled {
            return ChangingSampleMergeQueue()
        }
        #endif
        return SampleMergeQueue()
    }
}

#if DEBUG
/// UI テスト用（DEBUG だけ）。`-AskHubSampleChanges` を `-AskHubSampleInbox` と一緒に付けると、デモモードの取得元が更新のたびに違う中身を返す。
///
/// 一覧（`List`）の差分を当てるときに落ちないことを確かめるため（Discussion #743）、要素の増減・並びの入れ替え・重複（AskHubKit の除去が効くか）・
/// ステータスタブのループ 1 つ ↔ 2 つ・担当 PC あり → なし（「担当から外す」を送ったリポジトリ）を起こす
nonisolated enum SampleChanges {
    static let launchArgument = "-AskHubSampleChanges"
    /// 取得の回数と、「担当から外す」を送ったリポジトリ
    static let state = SampleChangesState()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// 取得の回数 `generation`（0 から）に応じて、並びを入れ替え・先頭を減らし・`duplicates` なら同じ要素を混ぜる。3 回に 1 回は元のまま
    static func vary<Element>(_ items: [Element], generation: Int, duplicates: Bool) -> [Element] {
        guard let first = items.first, let last = items.last else {
            return items
        }
        switch generation % 3 {
        case 1:
            return items.reversed() + (duplicates ? [first] : [])

        case 2:
            return Array(items.dropFirst()) + (duplicates ? [last] : [])

        default:
            return items
        }
    }
}

/// `SampleChanges` の状態。取得の口ごとに回数を数える
actor SampleChangesState {
    enum Key: Hashable, Sendable {
        case loopStatus, subjects, issues, waiting, usageLimited, manualLoops, mergeQueue
    }

    private var generations: [Key: Int] = [:]
    /// 「担当から外す」を送ったリポジトリ（小文字）
    private(set) var removedRepositories: Set<String> = []

    /// 取得の回数を 1 つ進めて返す（最初の取得は 0）
    func advance(_ key: Key) -> Int {
        let next = (generations[key] ?? -1) + 1
        generations[key] = next
        return next
    }

    /// 今の取得の回数（同じ取得の中の続きの問い合わせに使う）
    func current(_ key: Key) -> Int {
        generations[key] ?? 0
    }

    func markRemoved(_ repository: String) {
        removedRepositories.insert(repository.lowercased())
    }
}

/// 更新のたびに中身が変わるステータスタブの取得元
nonisolated struct ChangingSampleLoopStatusSource: LoopStatusSource {
    private let base = SampleLoopStatusSource()

    func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
        let generation = await SampleChanges.state.advance(.loopStatus)
        return await Self.changed(try await base.loopStatusRepositories(orgs: orgs), generation: generation)
    }

    /// コメントは、同じ取得の一覧（回数を進めない）から返す
    func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        let owner = String(repository.split(separator: "/").first ?? "")
        let generation = await SampleChanges.state.current(.loopStatus)
        return await Self.changed(try await base.loopStatusRepositories(orgs: [owner]), generation: generation)
            .first { $0.repository == repository }?
            .issues.first { $0.number == number }?
            .comments ?? []
    }

    private static func changed(_ repositories: [LoopStatusRepository], generation: Int) async -> [LoopStatusRepository] {
        let removed = await SampleChanges.state.removedRepositories
        let phase = generation % 3
        var changed = repositories.compactMap { repository -> LoopStatusRepository? in
            if removed.contains(repository.repository.lowercased()) {
                return removedRepository(repository)
            }
            return changedRepository(repository, phase: phase)
        }
        if phase == 1, let first = changed.first {
            // 大文字小文字だけ違う同じリポジトリ（organization の設定の重複など）。AskHubKit が 1 行にまとめる
            var duplicate = first
            duplicate.repository = first.repository.uppercased()
            changed.append(duplicate)
        }
        return changed
    }

    /// 担当から外された: オーケストレーターが担当の印を書かなくなり、状態用の Issue も閉じた（「担当 PC なし」の 1 行になる）
    private static func removedRepository(_ repository: LoopStatusRepository) -> LoopStatusRepository {
        var repository = repository
        repository.heartbeatDescription = OrchestratorHeartbeat.description(at: Date().addingTimeInterval(-60 * 60))
        repository.issues = []
        return repository
    }

    private static func changedRepository(_ repository: LoopStatusRepository, phase: Int) -> LoopStatusRepository? {
        var repository = repository
        switch (repository.repository.split(separator: "/").last.map(String.init) ?? "", phase) {
        case ("focus-timer-ios", 1), ("focus-timer-ios", 2):
            // ループ 2 つ → 1 つ（見出し + 2 行 → 1 行）
            repository.issues = repository.issues.map { issue in
                var issue = issue
                issue.comments = Array(issue.comments.prefix(1))
                return issue
            }

        case ("lingo-cards", 1):
            // ループ 1 つ → 2 つ（1 行 → 見出し + 2 行）
            repository.issues = repository.issues.map(addingLoop)

        case ("dotfiles", 1), ("ask-hub-apple", 2):
            // 行の増減。ask-hub-apple を外すと、ビルドの Mac と直近 24 時間の移動も消える
            return nil

        default:
            break
        }
        return repository
    }

    private static func addingLoop(to issue: LoopStatusIssue) -> LoopStatusIssue {
        var issue = issue
        let report = LoopStatusReport(state: .running, epic: "epic/review", discussion: 2, checkedAt: Date().addingTimeInterval(-60))
        let author = TrustedAuthors.defaultLogins[0]
        issue.comments.append(LoopStatusComment(id: issue.number * 100 + 99, author: author, updatedAt: Date(), body: report.issueBody))
        return issue
    }
}

/// 更新のたびに中身が変わる受信箱（要対応・任意判断・実機確認）と、ステータスタブの開始待ち・上限・手動ループの取得元。重複も混ぜる
nonisolated struct ChangingSampleInboxSource: InboxSource {
    private let base = SampleInboxSource()

    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        try await Self.vary(.subjects, base.subjectsNeedingAnswer(orgs: orgs))
    }

    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        try await base.questionThreads(of: subject)
    }

    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        try await Self.vary(.issues, base.lowPriorityIssues(orgs: orgs))
    }

    func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        try await Self.vary(.waiting, base.waitingDiscussions(orgs: orgs))
    }

    func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        try await Self.vary(.usageLimited, base.usageLimitedRepositories(orgs: orgs, now: now))
    }

    func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        try await Self.vary(.manualLoops, base.manualLoopRecords(orgs: orgs))
    }

    private static func vary<Element>(_ key: SampleChangesState.Key, _ items: [Element]) async -> [Element] {
        SampleChanges.vary(items, generation: await SampleChanges.state.advance(key), duplicates: true)
    }
}

/// 更新のたびに中身が変わるマージ待ちの取得元。重複の除去は `GitHubMergeQueue` の中で行うので、ここでは重複を混ぜない
nonisolated struct ChangingSampleMergeQueue: MergeQueueProviding {
    private let base = SampleMergeQueue()

    func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
        let generation = await SampleChanges.state.advance(.mergeQueue)
        return SampleChanges.vary(try await base.epicPullRequests(orgs: orgs), generation: generation, duplicates: false)
    }

    func merge(_ pullRequest: EpicPullRequest) async throws {
        try await base.merge(pullRequest)
    }
}
#endif
