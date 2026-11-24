import Foundation

// MARK: - 実機確認が残っている、マージした epic

extension DemoData {
    /// 実機確認が残っている、マージした epic（振り返りの epic のほか）。雨雲チェックは確かめるもの、
    /// 献立メモは、マージした後に 2.0.1 を配信したので「配信した版の確認」として畳む
    func verificationEpics() -> [Epic] {
        [
            mergedEpic(MergedSample(
                id: "rain-widget",
                title: "ウィジェットに降り始めの時刻を出す",
                repository: "rain-ios",
                summary: "ホーム画面で、雨が降り始める時刻を知りたい",
                pullRequest: 44,
                mergedAt: ago(minutes: 60 * 5),
                checks: [
                    "ホーム画面のウィジェットに、降り始めの時刻が出る",
                    "雨の予報が無いときは「しばらく降りません」と出る",
                    "ダークモードでも時刻が読める"
                ]
            )),
            mergedEpic(MergedSample(
                id: "recipe-cart",
                title: "材料を買い物リストに送る",
                repository: "recipe-apple",
                summary: "献立の材料を、そのまま買い物リストにしたい",
                pullRequest: 176,
                mergedAt: ago(minutes: 60 * 24 * 12),
                checks: [
                    "材料の「買い物リストに送る」で、リマインダーに足される",
                    "同じ材料を 2 回送っても重ならない"
                ]
            ))
        ]
    }

    /// 自動でマージし、完了の条件（`checks`）を実機で確かめるのを待っている epic の中身
    private struct MergedSample {
        var id: String
        var title: String
        var repository: String
        var summary: String
        var pullRequest: Int
        var mergedAt: Date
        var checks: [String]
    }

    private func mergedEpic(_ sample: MergedSample) -> Epic {
        let (id, title, summary, pullRequest, mergedAt) = (sample.id, sample.title, sample.summary, sample.pullRequest, sample.mergedAt)
        let review = FinalReview(
            pullRequestNumber: pullRequest,
            additions: nil,
            deletions: nil,
            headCommit: nil,
            reviewedHeadCommit: nil,
            checks: FinalChecks(ci: .passed, requiredFindings: 0, securityFindings: 0, hasConflict: false),
            mergePolicy: .automatic,
            decisions: [],
            internalDecisions: [],
            verifications: sample.checks.enumerated().map { offset, text in
                VerificationItem(id: "v\(offset + 1)", text: text, steps: "", state: .ready(build: nil))
            },
            state: .merged(at: mergedAt, automatic: true)
        )
        return Epic(
            id: id,
            title: title,
            repositoryID: Self.repositoryID(sample.repository),
            request: EpicRequest(
                summary: summary,
                body: "\(summary)。",
                requestedAt: mergedAt.addingTimeInterval(-2 * 24 * 60 * 60),
                source: .app,
                attachmentCount: 0
            ),
            stage: .done,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: [],
            macID: Self.macMiniID,
            activities: [],
            blocker: nil,
            finalReview: review,
            history: [Epic.HistoryEntry(date: mergedAt, text: "判断をすべて人がしたので、自動でマージしました（#\(pullRequest)）")],
            updatedAt: mergedAt
        )
    }
}
