import Foundation

// MARK: - 最終 PR と、終わった epic

extension DemoData {
    /// 積読リスト: 最終 PR の判断のカード（2 件は確認済み）。CI はランナーの空きを待っている
    func tsundokuEpic() -> Epic {
        let titles = ["検索のモデル", "検索欄", "一致した文字を強調する", "並べ替えのメニュー", "読み終えた本をまとめる", "デモのデータを増やす"]
        let tasks = titles.enumerated().map { index, title in
            EpicTask(id: "tsundoku-t\(index + 1)", number: index + 1, title: title, state: .done(pullRequest: 51 + index))
        }
        return Epic(
            id: "tsundoku-search",
            title: "本の並べ替えと検索",
            repositoryID: Self.repositoryID("tsundoku-ios"),
            request: EpicRequest(
                summary: "積んだ本が増えたので、探しやすくしたい",
                body: "タイトルで検索したい。読み終えた本は後ろに回したい。",
                requestedAt: ago(minutes: 60 * 50),
                source: .app,
                attachmentCount: 0
            ),
            stage: .finalReview,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: tasks,
            macID: Self.macBookProID,
            activities: [EpicActivity(kind: .waitingForRunner(retry: 2, nextAt: later(minutes: 14)), since: ago(minutes: 32))],
            blocker: nil,
            finalReview: tsundokuReview(),
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 50), text: "依頼しました"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 40), text: "MacBook Pro 14 で開始しました"),
                Epic.HistoryEntry(date: ago(minutes: 90), text: "タスク 6 をマージしました（#56）"),
                Epic.HistoryEntry(date: ago(minutes: 60), text: "最終 PR #57 を出しました"),
                Epic.HistoryEntry(date: ago(minutes: 32), text: "CI のランナーが割り当てられないため、再試行を待っています")
            ],
            updatedAt: ago(minutes: 32)
        )
    }

    private func tsundokuReview() -> FinalReview {
        FinalReview(
            pullRequestNumber: 57,
            additions: 1_204,
            deletions: 310,
            headCommit: "9f3c2e1",
            reviewedHeadCommit: nil,
            checks: FinalChecks(
                ci: .waitingForRunner(retry: 2, nextAt: later(minutes: 14)),
                requiredFindings: 0,
                securityFindings: 0,
                hasConflict: false
            ),
            mergePolicy: .manual([.visibleDecisions(count: 5)]),
            decisions: tsundokuConfirmedDecisions() + tsundokuPendingDecisions(),
            internalDecisions: [
                "検索は大文字と小文字、ひらがなとカタカナを区別しない",
                "並べ替えの設定は UserDefaults に置く",
                "検索は入力が止まってから 0.3 秒待って絞り込む",
                "一覧の差分は本の id で取る",
                "デモのデータに本を 40 冊足した",
                "使われなくなった並べ替えのコードを消した"
            ],
            verifications: [
                VerificationItem(
                    id: "tsundoku-v1",
                    text: "100 冊あっても一覧がなめらかに動く",
                    steps: "デモのデータで一覧を速くスクロールする",
                    state: .waitingForBuild
                ),
                VerificationItem(
                    id: "tsundoku-v2",
                    text: "VoiceOver で並べ替えのメニューを操作できる",
                    steps: "VoiceOver をオンにして、ツールバーの並べ替えを開く",
                    state: .waitingForBuild
                )
            ],
            state: .reviewable
        )
    }

    private func tsundokuConfirmedDecisions() -> [DecisionCard] {
        [
            DecisionCard(
                id: "d1",
                title: "検索欄を一覧の上に常に出した",
                reason: "本が多い人は検索から探すことが多いため",
                goalSource: "完了の条件 2「タイトルの一部で本を探せる」",
                alternatives: ["下に引っぱったときだけ出す"],
                before: .demo(Self.bookList(search: false, highlightSearch: false)),
                after: .demo(Self.bookList(search: true, highlightSearch: true)),
                response: .accepted
            ),
            DecisionCard(
                id: "d2",
                title: "読み終えた本を一覧の下にまとめた",
                reason: "未読の本を先に見たいという依頼から",
                goalSource: "決まったこと「読み終えた本は後ろに回す」",
                alternatives: ["読み終えた本を別のタブに分ける"],
                before: .demo(Self.bookList(search: false, highlightSearch: false)),
                after: .demo(Self.bookList(search: true, highlightSearch: false, finishedSection: true)),
                response: .accepted
            )
        ]
    }

    private func tsundokuPendingDecisions() -> [DecisionCard] {
        [
            DecisionCard(
                id: "d3",
                title: "並べ替えの既定を「追加した順」にした",
                reason: "今の一覧と同じ並びで、開いたときに迷わない",
                goalSource: "タスク 4「並べ替えのメニュー」",
                alternatives: ["タイトル順にする", "著者順にする"],
                before: nil,
                after: nil,
                response: .pending
            ),
            DecisionCard(
                id: "d4",
                title: "並べ替えのメニューをツールバーの右に置いた",
                reason: "iOS の標準の置き場所に合わせた",
                goalSource: "タスク 4「並べ替えのメニュー」",
                alternatives: ["一覧の上の切り替えにする"],
                before: .demo(Self.bookList(search: true, highlightSearch: false)),
                after: .demo(Self.bookList(search: true, highlightSearch: false, sortButton: true)),
                response: .pending
            ),
            DecisionCard(
                id: "d5",
                title: "検索で一致した文字を太字にした",
                reason: "どこが一致したか分かるように",
                goalSource: "タスク 3「一致した文字を強調する」",
                alternatives: [],
                before: .demo(Self.searchResults(bold: false)),
                after: .demo(Self.searchResults(bold: true)),
                response: .pending
            )
        ]
    }

    static func bookList(search: Bool, highlightSearch: Bool, finishedSection: Bool = false, sortButton: Bool = false) -> DemoScreen {
        var elements: [DemoScreen.Element] = []
        if search {
            elements.append(.search(highlighted: highlightSearch))
        }
        elements += [
            .row("夜の図書館", detail: "未読", highlighted: false),
            .row("はじめての庭づくり", detail: "未読", highlighted: false),
            .row("旅する数学", detail: "読書中", highlighted: false)
        ]
        if finishedSection {
            elements.append(.section("読み終えた本", highlighted: true))
        }
        elements.append(.row("海辺の喫茶店", detail: "読了", highlighted: finishedSection))
        return DemoScreen(title: "積読リスト", toolbarItem: sortButton ? "並べ替え" : nil, toolbarItemHighlighted: sortButton, elements: elements)
    }

    static func searchResults(bold: Bool) -> DemoScreen {
        DemoScreen(
            title: "積読リスト",
            elements: [
                .search(highlighted: false),
                .row(bold ? "**庭**づくりの基本" : "庭づくりの基本", detail: "未読", highlighted: bold),
                .row(bold ? "はじめての**庭**づくり" : "はじめての庭づくり", detail: "未読", highlighted: bold)
            ]
        )
    }

    /// 習慣ログ: 自動でマージした epic。TestFlight に上がったので実機確認ができる
    func habitDoneEpic() -> Epic {
        Epic(
            id: "habit-review",
            title: "週の振り返り画面",
            repositoryID: Self.repositoryID("habit-ios"),
            request: EpicRequest(
                summary: "1 週間の記録を振り返る画面がほしい",
                body: "日曜の夜に 1 週間の達成をグラフで見たい。",
                requestedAt: ago(minutes: 60 * 72),
                source: .app,
                attachmentCount: 0
            ),
            stage: .done,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: [],
            macID: Self.macBookProID,
            activities: [],
            blocker: nil,
            finalReview: habitDoneReview(),
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 40), text: "判断をすべて人がしたので、自動でマージしました（#31）"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 30), text: "TestFlight 1.4.0 (52) に入りました")
            ],
            updatedAt: ago(minutes: 60 * 30)
        )
    }

    /// 前に終わった epic（`manyFinished` の場面）。新しい順に 1 日ずつ前に終わり、いくつかはやめた
    func pastEpics() -> [Epic] {
        let past: [(repository: String, title: String)] = [
            ("recipe-apple", "材料の分量を人数で変える"),
            ("rain-ios", "降り始めの通知"),
            ("habit-ios", "続いた日数を出す"),
            ("pocket-budget-ios", "レシートの写真を添える"),
            ("tsundoku-ios", "読み終えた本のメモ"),
            ("kaji-share-ios", "当番の入れ替え"),
            ("habit-ios", "ウィジェットの色を選ぶ"),
            ("recipe-apple", "献立を家族と共有する"),
            ("rain-ios", "雨雲の地図を広げる"),
            ("tsundoku-ios", "バーコードで本を足す"),
            ("pocket-budget-ios", "月ごとのグラフ"),
            ("kaji-share-ios", "家事にかかった時間")
        ]
        // やめた epic（4 つ目と 8 つ目）
        let abandoned: Set<Int> = [3, 7]
        return past.enumerated().map { index, item in
            let isAbandoned = abandoned.contains(index)
            let finishedAt = ago(minutes: 60 * 24 * Double(index + 2))
            var epic = Epic(
                id: "past-\(index + 1)",
                title: item.title,
                repositoryID: Self.repositoryID(item.repository),
                request: EpicRequest(
                    summary: item.title,
                    body: "\(item.title)。",
                    requestedAt: finishedAt.addingTimeInterval(-3 * 24 * 60 * 60),
                    source: .app,
                    attachmentCount: 0
                ),
                stage: isAbandoned ? .questions : .done,
                questions: [],
                goal: nil,
                humanTasks: [],
                tasks: [],
                macID: Self.macMiniID,
                activities: [],
                blocker: nil,
                finalReview: isAbandoned ? nil : pastReview(number: 20 - index, mergedAt: finishedAt),
                history: [Epic.HistoryEntry(date: finishedAt, text: isAbandoned ? "やめました" : "マージしました（#\(20 - index)）")],
                updatedAt: finishedAt
            )
            epic.isAbandoned = isAbandoned
            return epic
        }
    }

    private func pastReview(number: Int, mergedAt: Date) -> FinalReview {
        FinalReview(
            pullRequestNumber: number,
            additions: nil,
            deletions: nil,
            headCommit: nil,
            reviewedHeadCommit: nil,
            checks: FinalChecks(ci: .passed, requiredFindings: 0, securityFindings: 0, hasConflict: false),
            mergePolicy: .manual([]),
            decisions: [],
            internalDecisions: [],
            verifications: [],
            state: .merged(at: mergedAt, automatic: false)
        )
    }

    private func habitDoneReview() -> FinalReview {
        FinalReview(
            pullRequestNumber: 31,
            additions: 640,
            deletions: 52,
            headCommit: "4b1d77a",
            reviewedHeadCommit: "4b1d77a",
            checks: FinalChecks(ci: .passed, requiredFindings: 0, securityFindings: 0, hasConflict: false),
            mergePolicy: .automatic,
            decisions: [],
            internalDecisions: ["グラフは Swift Charts で描く"],
            verifications: [
                VerificationItem(
                    id: "habit-v1",
                    text: "振り返りの画面を日曜の夜に開ける",
                    steps: "日曜の夜 8 時以降に、ホームの「今週」を押す",
                    state: .ready(build: "1.4.0 (52)")
                ),
                VerificationItem(
                    id: "habit-v2",
                    text: "グラフの色がダークモードでも読める",
                    steps: "ダークモードにして、振り返りの画面を開く",
                    state: .ready(build: "1.4.0 (52)")
                )
            ],
            state: .merged(at: ago(minutes: 60 * 40), automatic: true)
        )
    }
}
