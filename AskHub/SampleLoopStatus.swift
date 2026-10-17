import AskHubKit
import Foundation

extension LoopStatusModel {
    /// アプリの起動時に使うモデル。デモモードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> LoopStatusModel {
        if DemoMode.isEnabled {
            return sample()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            return sample()
        }
        #endif
        return LoopStatusModel()
    }

    /// デモモード・Preview・UI テスト用。GitHub には接続しない。
    /// 「上限で待機中」「ループの開始待ち」は受信箱のサンプル（`SampleInboxSource`）から出す
    static func sample() -> LoopStatusModel {
        LoopStatusModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeSource: { _ in SampleLoopStatusSource() },
            makeInboxSource: { _ in SampleInboxSource() },
            // サンプルは GitHub に権限を問い合わせない
            makeTrust: { _ in TrustedAuthors.default },
            makeStarter: { _ in SampleLoopStarter() },
            makeFinalInstructions: { _, _ in SampleManualLoopFinalInstructions() }
        )
    }
}

/// デモモード・Preview・UI テスト用。zankyo-apple #8 の手動ループの最終 PR に未処理の指示がある（担当者に再開を促す）
struct SampleManualLoopFinalInstructions: ManualLoopFinalInstructionsChecking {
    static let pending: Set<String> = [ManualLoopTarget.key(repository: "shilokuma-inc/zankyo-apple", discussion: 8)]

    func loopsWithUnprocessedInstructions(_ loops: [ManualLoopTarget]) async throws -> Set<String> {
        Self.pending.intersection(loops.map(\.key))
    }
}

/// デモモード・Preview・UI テスト用の固定のループの状態。すべての状態（停滞・担当 PC なし・状態なしを含む）を 1 行ずつ出す。
/// 同じリポジトリで自動ループと手動ループ・手動ループ 2 つが同時に回っている例（リポジトリの見出しの下にループを並べる）も出す。
/// 進捗のゲージは 0%・各段階・100%・進捗なしの行が出るようにしている。
/// ビルドの行は、別の Mac に移って実行中・Mac の空き待ち・直近の成功と失敗が出るようにしている。
/// 「ビルドの Mac」は、使える・切断・待機の Mac と、24 時間の移動（成功・失敗）が出るようにしている
struct SampleLoopStatusSource: LoopStatusSource {
    func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
        // サンプルのリポジトリは先頭の organization に置く
        let org = orgs.first ?? TargetOrganizations.defaultLogins[0]
        // 時刻は取得のたびに今からの相対で作る（担当 PC の有無や「最後の動き」が古くならないように）
        let now = Date()
        func minutesAgo(_ minutes: Double) -> Date {
            now.addingTimeInterval(-minutes * 60)
        }
        /// 信用する author の状態用の Issue があるリポジトリ。`progress` は（終わったタスク, すべてのタスク）、`deferred` はそのうち保留で閉じたタスク、`active` は最後の動きが何分前か、`resumesIn` は上限の解除が何分後か
        func reported(
            _ name: String,
            issue number: Int,
            _ state: LoopStatusReport.State,
            _ epic: String? = nil,
            goal discussion: Int? = nil,
            progress: (Int, Int)? = nil,
            deferred: Int? = nil,
            active: Double? = nil,
            resumesIn: Double? = nil
        ) -> LoopStatusRepository {
            let report = LoopStatusReport(
                state: state,
                epic: epic,
                discussion: discussion,
                progress: progress.map { LoopStatusReport.Progress(completed: $0.0, total: $0.1, deferred: deferred) },
                lastActivityAt: active.map(minutesAgo),
                usageLimitedUntil: resumesIn.map { now.addingTimeInterval($0 * 60) },
                checkedAt: minutesAgo(2),
                builds: Self.builds(of: name, now: now)
            )
            let issue = Self.issue(org, name, number: number, report: report, updatedAt: minutesAgo(2))
            return Self.repository(org, name, heartbeat: minutesAgo(2), issues: [issue])
        }

        return [
            // ビルドの Mac の状態の Issue もここに置く
            reported("ask-hub-apple", issue: 219, .running, "epic/loop-status", goal: 211, progress: (5, 12), active: 3),
            // 実行中なのに長く動きが無い
            reported("beat-tap-ios", issue: 7, .running, "epic/practice-mode", goal: 3, progress: (2, 8), active: 95),
            reported("claude-plugins", issue: 14, .waitingForAnswer, "epic/hooks", goal: 9, progress: (6, 7), active: 40),
            reported("dotfiles", issue: 2, .noLoop),
            // 保留で閉じたタスクがある
            reported("habit-log-ios", issue: 31, .gaveUp, "epic/widgets", goal: 22, progress: (3, 10), deferred: 1, active: 180),
            reported("lingo-cards", issue: 5, .completed, "epic/mvp", goal: 1, progress: (9, 9), deferred: 2, active: 600),
            reported("notti-ios", issue: 44, .usageLimited, "epic/notification", goal: 12, progress: (4, 11), active: 20, resumesIn: 120),
            // 担当 PC はいるが、状態用の Issue がまだ無い
            Self.repository(org, "pocket-budget", heartbeat: minutesAgo(5), issues: []),
            // 手で始めた epic（ゴール元の記録が無い）
            reported("recipe-box", issue: 3, .waitingToStart, "epic/search", progress: (0, 6), active: 300),
            // 担当の印も状態の確認時刻も古い
            Self.repository(org, "weather-mini", heartbeat: minutesAgo(3 * 60), issues: [
                Self.issue(
                    org,
                    "weather-mini",
                    number: 8,
                    report: LoopStatusReport(state: .running, epic: "epic/radar", discussion: 4, checkedAt: minutesAgo(3 * 60)),
                    updatedAt: minutesAgo(3 * 60)
                )
            ])
        ] + Self.concurrentLoops(org, now: now)
    }

    /// 同じリポジトリで複数のループが同時に回っている例（リポジトリの見出しの下にループを並べる）
    private static func concurrentLoops(_ org: String, now: Date) -> [LoopStatusRepository] {
        func minutesAgo(_ minutes: Double) -> Date {
            now.addingTimeInterval(-minutes * 60)
        }
        return [
            // 同じリポジトリで、自動ループと手動ループが同時に回っている（ループごとのコメント）
            Self.loops(org, "pair-quiz-ios", issue: 9, checkedAt: minutesAgo(2), [
                LoopStatusReport(
                    state: .running,
                    epic: "epic/ranking",
                    discussion: 50,
                    progress: .init(completed: 3, total: 7, deferred: 0),
                    lastActivityAt: minutesAgo(4),
                    checkedAt: minutesAgo(2)
                ),
                LoopStatusReport(
                    state: .waitingForAnswer,
                    writer: .manual,
                    epic: "epic/share",
                    discussion: 52,
                    progress: .init(completed: 4, total: 6, deferred: 0),
                    lastActivityAt: minutesAgo(25),
                    checkedAt: minutesAgo(5),
                    runner: "partner",
                    waitingPullRequests: [58]
                )
            ]),
            // 同じリポジトリで、手動ループが 2 つ回っている
            Self.loops(org, "story-maker", issue: 4, checkedAt: minutesAgo(2), [
                LoopStatusReport(
                    state: .running,
                    writer: .manual,
                    epic: "epic/illustrations",
                    discussion: 61,
                    progress: .init(completed: 1, total: 5, deferred: 0),
                    lastActivityAt: minutesAgo(1),
                    checkedAt: minutesAgo(1),
                    runner: TrustedAuthors.defaultLogins[0]
                ),
                LoopStatusReport(
                    state: .waitingToStart,
                    writer: .manual,
                    epic: "epic/voice",
                    discussion: 63,
                    progress: .init(completed: 2, total: 8, deferred: 0),
                    lastActivityAt: minutesAgo(50),
                    checkedAt: minutesAgo(8),
                    runner: "partner"
                )
            ]),
            Self.launchedAfterCompletedEpic(org, now: now)
        ]
    }

    /// 完了した epic（最終 PR のマージ待ち）が残ったまま、次の Discussion の自動ループを起動した例（自動ループも Discussion ごとのコメント）
    private static func launchedAfterCompletedEpic(_ org: String, now: Date) -> LoopStatusRepository {
        let checkedAt = now.addingTimeInterval(-2 * 60)
        return Self.loops(org, "focus-timer-ios", issue: 6, checkedAt: checkedAt, [
            LoopStatusReport(
                state: .completed,
                epic: "epic/themes",
                discussion: 70,
                progress: .init(completed: 6, total: 6, deferred: 0),
                lastActivityAt: now.addingTimeInterval(-90 * 60),
                checkedAt: checkedAt
            ),
            LoopStatusReport(state: .running, discussion: 74, checkedAt: checkedAt)
        ])
    }

    /// ループごとの状態はサンプルの一覧に入れておき、取得の口（`LoopStatusFetcher` が使う Issue だけを取る）でもそこから返す
    func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        let owner = String(repository.split(separator: "/").first ?? "")
        return try await loopStatusRepositories(orgs: [owner])
            .first { $0.repository == repository }?
            .issues.first { $0.number == number }?
            .comments ?? []
    }

    /// 状態用の Issue の本文（新しい形。リポジトリ全体の状態）と、ループごとのコメントを持つリポジトリ
    private static func loops(
        _ org: String, _ name: String, issue number: Int, checkedAt: Date, _ reports: [LoopStatusReport]
    ) -> LoopStatusRepository {
        // 本文の目印（`ask-hub:repository-status`）。オーケストレーターが書く形と同じ
        let body = #"<!-- ask-hub:repository-status {"checkedAt":""# + checkedAt.formatted(.iso8601) + #""} -->"#
        let comments = reports.enumerated().map { index, report in
            LoopStatusComment(
                id: number * 100 + index, author: TrustedAuthors.defaultLogins[0], updatedAt: report.checkedAt, body: report.issueBody
            )
        }
        var issue = issue(org, name, number: number, body: body, updatedAt: checkedAt)
        issue.comments = comments
        return repository(org, name, heartbeat: checkedAt, issues: [issue])
    }

    /// ビルドの行のサンプル。ほかのリポジトリはビルドの情報を持たない
    private static func builds(of name: String, now: Date) -> LoopStatusBuilds? {
        switch name {
        case "ask-hub-apple": movedBuilds(now)
        case "beat-tap-ios": waitingBuilds(now)
        default: nil
        }
    }

    /// 持ち出しで切断された Mac から移って、別の Mac でビルドしている。もう一方のスロットは直近のテストが成功
    private static func movedBuilds(_ now: Date) -> LoopStatusBuilds {
        let move = LoopStatusBuildMove(
            from: "macbookpro-m1pro", to: "macbookpro-m4max", reason: .disconnected, movedAt: now.addingTimeInterval(-4 * 60)
        )
        return LoopStatusBuilds(
            running: [
                LoopStatusBuild(
                    slot: "a",
                    action: "build",
                    platform: "iOS",
                    host: "macbookpro-m4max",
                    attempt: 2,
                    moves: [move],
                    startedAt: now.addingTimeInterval(-6 * 60)
                )
            ],
            latest: [
                LoopStatusBuild(
                    slot: "b",
                    action: "test",
                    platform: "macOS",
                    host: "local",
                    attempt: 1,
                    exitCode: 0,
                    seconds: 95,
                    finishedAt: now.addingTimeInterval(-12 * 60)
                )
            ],
            moved: [
                LoopStatusBuild(
                    slot: "b",
                    action: "test",
                    platform: "iOS",
                    host: "macbookpro-m4max",
                    attempt: 2,
                    moves: [LoopStatusBuildMove(from: "macbookpro-m1pro", to: "macbookpro-m4max", reason: .disconnected)],
                    exitCode: 0,
                    finishedAt: now.addingTimeInterval(-2 * 60 * 60)
                )
            ]
        )
    }

    /// Mac の空き待ちと、直近のビルドの失敗
    private static func waitingBuilds(_ now: Date) -> LoopStatusBuilds {
        LoopStatusBuilds(
            running: [LoopStatusBuild(slot: "a", action: "test", platform: "iOS", attempt: 1, startedAt: now.addingTimeInterval(-60))],
            latest: [
                LoopStatusBuild(
                    slot: "b",
                    action: "build",
                    platform: "iOS",
                    host: "macbookpro-m1pro",
                    attempt: 1,
                    exitCode: 65,
                    finishedAt: now.addingTimeInterval(-30 * 60)
                )
            ],
            moved: [
                LoopStatusBuild(
                    slot: "a",
                    action: "build",
                    platform: "iOS",
                    host: "local",
                    attempt: 3,
                    moves: [
                        LoopStatusBuildMove(from: "macbookpro-m1pro", to: "macbookpro-m4max", reason: .disconnected),
                        LoopStatusBuildMove(from: "macbookpro-m4max", to: "local", reason: .disconnected)
                    ],
                    exitCode: 65,
                    finishedAt: now.addingTimeInterval(-5 * 60 * 60)
                )
            ]
        )
    }

    private static func repository(_ org: String, _ name: String, heartbeat: Date, issues: [LoopStatusIssue]) -> LoopStatusRepository {
        LoopStatusRepository(
            repository: "\(org)/\(name)",
            heartbeatDescription: OrchestratorHeartbeat.description(at: heartbeat),
            issues: issues,
            // 担当の印は数分前に書かれているので、その時刻を今として作る
            buildHostsIssues: buildHostsIssues(org, name, now: heartbeat.addingTimeInterval(2 * 60))
        )
    }

    private static func issue(_ org: String, _ name: String, number: Int, report: LoopStatusReport, updatedAt: Date) -> LoopStatusIssue {
        issue(org, name, number: number, body: report.issueBody, updatedAt: updatedAt)
    }

    private static func issue(_ org: String, _ name: String, number: Int, body: String, updatedAt: Date) -> LoopStatusIssue {
        LoopStatusIssue(
            number: number,
            url: URL(string: "https://github.com/\(org)/\(name)/issues/\(number)")!,
            author: TrustedAuthors.defaultLogins[0],
            updatedAt: updatedAt,
            body: body
        )
    }

    /// ビルドの Mac の状態の Issue は ask-hub-apple にだけ置く
    private static func buildHostsIssues(_ org: String, _ name: String, now: Date) -> [LoopStatusIssue] {
        guard name == "ask-hub-apple" else {
            return []
        }
        return [issue(org, name, number: 366, body: buildHosts(org, now).issueBody, updatedAt: now.addingTimeInterval(-3 * 60))]
    }

    /// 3 台の Mac（使える・持ち出しで切断）と、リモートが無いときだけ使う Mac mini（local）
    private static func buildHosts(_ org: String, _ now: Date) -> BuildHostsReport {
        BuildHostsReport(
            hosts: [
                BuildHost(name: "macbookpro-m4max", state: .ok, cores: 14, load: 3.25, memoryFreePercent: 41, running: 1, slots: 2),
                BuildHost(name: "macbookpro-m1pro", state: .down, reason: .unreachable, running: 0, slots: 1),
                BuildHost(name: "local", state: .standby, running: 0, slots: 1)
            ],
            jobs: [
                BuildHostJob(
                    host: "macbookpro-m4max",
                    repository: "\(org)/ask-hub-apple",
                    slot: "a",
                    action: "build",
                    platform: "iOS",
                    attempt: 2,
                    startedAt: now.addingTimeInterval(-6 * 60)
                )
            ],
            measuredAt: now.addingTimeInterval(-3 * 60),
            checkedAt: now.addingTimeInterval(-3 * 60)
        )
    }
}
