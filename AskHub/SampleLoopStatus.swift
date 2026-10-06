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

    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> LoopStatusModel {
        LoopStatusModel(tokenStore: InMemoryTokenStore(token: "sample")) { _ in SampleLoopStatusSource() }
    }
}

/// デモモード・Preview・UI テスト用の固定のループの状態。すべての状態（停滞・担当 PC なし・状態なしを含む）を 1 行ずつ出す
struct SampleLoopStatusSource: LoopStatusSource {
    func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
        // 時刻は取得のたびに今からの相対で作る（担当 PC の有無や「最後の動き」が古くならないように）
        let now = Date()
        func minutesAgo(_ minutes: Double) -> Date {
            now.addingTimeInterval(-minutes * 60)
        }
        /// 信用する author の状態用の Issue があるリポジトリ。`progress` は（終わったタスク, すべてのタスク）、`active` は最後の動きが何分前か、`resumesIn` は上限の解除が何分後か
        func reported(
            _ name: String,
            issue number: Int,
            _ state: LoopStatusReport.State,
            _ epic: String? = nil,
            goal discussion: Int? = nil,
            progress: (Int, Int)? = nil,
            active: Double? = nil,
            resumesIn: Double? = nil
        ) -> LoopStatusRepository {
            let report = LoopStatusReport(
                state: state,
                epic: epic,
                discussion: discussion,
                progress: progress.map { LoopStatusReport.Progress(completed: $0.0, total: $0.1) },
                lastActivityAt: active.map(minutesAgo),
                usageLimitedUntil: resumesIn.map { now.addingTimeInterval($0 * 60) },
                checkedAt: minutesAgo(2)
            )
            let issue = Self.issue(org, name, number: number, report: report, updatedAt: minutesAgo(2))
            return Self.repository(org, name, heartbeat: minutesAgo(2), issues: [issue])
        }

        return [
            reported("ask-hub-apple", issue: 219, .running, "epic/loop-status", goal: 211, progress: (5, 12), active: 3),
            // 実行中なのに長く動きが無い
            reported("beat-tap-ios", issue: 7, .running, "epic/practice-mode", goal: 3, progress: (2, 8), active: 95),
            reported("claude-plugins", issue: 14, .waitingForAnswer, "epic/hooks", goal: 9, progress: (6, 7), active: 40),
            reported("dotfiles", issue: 2, .noLoop),
            reported("habit-log-ios", issue: 31, .gaveUp, "epic/widgets", goal: 22, progress: (3, 10), active: 180),
            reported("lingo-cards", issue: 5, .completed, "epic/mvp", goal: 1, progress: (9, 9), active: 600),
            reported("notti-ios", issue: 44, .usageLimited, "epic/notification", goal: 12, progress: (4, 11), active: 20, resumesIn: 120),
            // 担当 PC はいるが、状態用の Issue がまだ無い
            Self.repository(org, "pocket-budget", heartbeat: minutesAgo(5), issues: []),
            // 手で始めた epic（ゴール元の記録が無い）
            reported("recipe-box", issue: 3, .waitingToStart, "epic/search", progress: (1, 6), active: 300),
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
        ]
    }

    private static func repository(_ org: String, _ name: String, heartbeat: Date, issues: [LoopStatusIssue]) -> LoopStatusRepository {
        LoopStatusRepository(
            repository: "\(org)/\(name)",
            heartbeatDescription: OrchestratorHeartbeat.description(at: heartbeat),
            issues: issues
        )
    }

    private static func issue(_ org: String, _ name: String, number: Int, report: LoopStatusReport, updatedAt: Date) -> LoopStatusIssue {
        LoopStatusIssue(
            number: number,
            url: URL(string: "https://github.com/\(org)/\(name)/issues/\(number)")!,
            author: TrustedAuthors.defaultLogins[0],
            updatedAt: updatedAt,
            body: report.issueBody
        )
    }
}
