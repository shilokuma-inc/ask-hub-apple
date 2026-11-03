import Foundation

// MARK: - 質問の段階の epic

extension DemoData {
    /// 献立メモ: 説明待ち・ロック（依存）・依存される質問を含む
    func recipeEpic() -> Epic {
        let asked = ago(minutes: 150)
        return Epic(
            id: "recipe-weekly",
            title: "週ごとのまとめ通知",
            repositoryID: Self.repositoryID("recipe-apple"),
            request: EpicRequest(
                summary: "毎朝の通知をやめ、週に 1 回のまとめにしたい",
                body: "毎朝届く通知が多いので、1 週間の献立と買い物の予定をまとめて 1 回で知らせてほしい。",
                requestedAt: ago(minutes: 180),
                source: .siri,
                attachmentCount: 0
            ),
            stage: .questions,
            questions: recipeAnsweredQuestions(asked: asked) + recipeOpenQuestions(asked: asked),
            goal: nil,
            humanTasks: [],
            tasks: [],
            macID: nil,
            activities: [EpicActivity(kind: .explaining("Q4"), since: ago(minutes: 6))],
            blocker: nil,
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 180), text: "Siri から依頼しました"),
                Epic.HistoryEntry(date: asked, text: "質問を 6 つ作りました"),
                Epic.HistoryEntry(date: ago(minutes: 120), text: "Q1 に回答しました"),
                Epic.HistoryEntry(date: ago(minutes: 118), text: "Q2 に回答しました"),
                Epic.HistoryEntry(date: ago(minutes: 6), text: "Q4 の説明を求めました")
            ],
            updatedAt: ago(minutes: 6)
        )
    }

    private func recipeAnsweredQuestions(asked: Date) -> [Question] {
        [
            Question(
                id: "Q1",
                title: "まとめに入れる中身",
                why: "まとめの画面と通知の文の作りが変わります",
                options: [
                    Self.option("a", "献立と買い物リスト", "今ある 2 つの画面から作れる"),
                    Self.option("b", "献立だけ", "いちばん短い。買い物は別に見る"),
                    Self.option("c", "献立・買い物・食材の期限", "期限のデータを新しく持つ必要がある")
                ],
                recommendedOptionID: "a",
                recommendationReason: "今のデータだけで作れ、通知が長くなりすぎない",
                state: .answered(Question.Response(optionID: "a", note: "", answeredAt: ago(minutes: 120))),
                askedAt: asked
            ),
            Question(
                id: "Q2",
                title: "通知を開いたときの行き先",
                why: "新しい画面を作るかどうかが変わります",
                options: [
                    Self.option("a", "今週の献立の画面", "今ある画面をそのまま使う"),
                    Self.option("b", "まとめの画面（新しく作る）", "通知の中身を並べた画面を作る")
                ],
                recommendedOptionID: "a",
                recommendationReason: "画面を増やさずに済み、迷わない",
                state: .answered(Question.Response(optionID: "a", note: "", answeredAt: ago(minutes: 118))),
                askedAt: asked
            ),
            Question(
                id: "Q3",
                title: "まとめを届ける曜日と時刻",
                why: "通知の予約の作りと、設定画面に項目を足すかが変わります",
                options: [
                    Self.option("a", "曜日と時刻を選べる", "設定に 2 項目。予約の作り直しが要る"),
                    Self.option("b", "月曜の朝 9 時に固定", "設定は増えず、実装がいちばん小さい"),
                    Self.option("c", "日曜の夜 8 時に固定", "週の振り返り向け。朝の習慣とずれる")
                ],
                recommendedOptionID: "b",
                recommendationReason: "朝に開く今の使われ方と合う",
                askedAt: asked
            )
        ]
    }

    private func recipeOpenQuestions(asked: Date) -> [Question] {
        [
            Question(
                id: "Q4",
                title: "読んだまとめを一覧に残すか",
                why: "まとめを保存するデータの持ち方が変わります",
                options: [Self.option("a", "残さない", "保存のデータを持たない"), Self.option("b", "過去 4 週を残す", "古いまとめを消す処理が要る")],
                recommendedOptionID: "a",
                recommendationReason: "通知の中身は献立の画面でいつでも見られる",
                state: .awaitingExplanation(requestedAt: ago(minutes: 6)),
                explanations: [Question.Explanation(request: "「一覧」がどの画面を指すのか分からない", requestedAt: ago(minutes: 6))],
                askedAt: asked
            ),
            Question(
                id: "Q5",
                title: "予定の時刻を過ぎてから開いたとき",
                why: "Q3 で固定の時刻にした場合、見逃したまとめの扱いが要ります",
                options: [Self.option("a", "次の週に回す", "見逃した分は出さない"), Self.option("b", "開いたときにすぐ出す", "アプリを開いたときに確かめる処理が要る")],
                recommendedOptionID: "a",
                recommendationReason: "通知が重ならない",
                dependsOn: ["Q3"],
                state: .locked,
                askedAt: asked
            ),
            Question(
                id: "Q6",
                title: "まとめの中の並び順",
                why: "Q3・Q4 の回答によって、並べる単位（日・週）が変わります",
                options: [Self.option("a", "日付の順", "献立の画面と同じ"), Self.option("b", "買い物の多い順", "買い物の量の計算が要る")],
                recommendedOptionID: "a",
                recommendationReason: "献立の画面と同じで迷わない",
                dependsOn: ["Q3", "Q4"],
                state: .locked,
                askedAt: asked
            )
        ]
    }

    /// 習慣ログ: 2 択・自由記述・4 択の質問
    func habitEpic() -> Epic {
        let asked = ago(minutes: 40)
        return Epic(
            id: "habit-export",
            title: "記録の書き出し",
            repositoryID: Self.repositoryID("habit-ios"),
            request: EpicRequest(
                summary: "記録をファイルに書き出して、ほかのアプリでも使いたい",
                body: "毎日の記録を表計算のアプリで集計したい。月ごとに書き出せるとうれしい。",
                requestedAt: ago(minutes: 55),
                source: .app,
                attachmentCount: 1
            ),
            stage: .questions,
            questions: habitQuestions(asked: asked),
            goal: nil,
            humanTasks: [],
            tasks: [],
            macID: nil,
            activities: [],
            blocker: nil,
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 55), text: "依頼しました（添付 1）"),
                Epic.HistoryEntry(date: asked, text: "質問を 4 つ作りました"),
                Epic.HistoryEntry(date: ago(minutes: 20), text: "Q1 に回答しました")
            ],
            updatedAt: ago(minutes: 20)
        )
    }

    private func habitQuestions(asked: Date) -> [Question] {
        [
            Question(
                id: "Q1",
                title: "書き出す期間の既定",
                why: "書き出しの画面に期間の選択を置くかが変わります",
                options: [Self.option("a", "今月", "期間の選択は出さない"), Self.option("b", "期間を選ぶ", "日付の選択を 2 つ置く")],
                recommendedOptionID: "a",
                recommendationReason: "依頼が「月ごと」なので",
                state: .answered(Question.Response(optionID: "b", note: "年末にまとめて出したい", answeredAt: ago(minutes: 20))),
                askedAt: asked
            ),
            Question(
                id: "Q2",
                title: "書き出したファイルの置き場所",
                why: "共有の画面の作りと、権限の説明の文言が変わります",
                options: [
                    Self.option("a", "共有シートだけ", "作りは最小。置き場所は相手のアプリ任せ"),
                    Self.option("b", "ファイル App に保存", "どこにでも置ける。画面が 1 つ増える")
                ],
                recommendedOptionID: "b",
                recommendationReason: "書き出した後に探しやすい",
                askedAt: asked
            ),
            Question(
                id: "Q3",
                title: "ファイル名の決まり",
                why: "書き出したファイルを並べたときの見分けやすさが変わります",
                recommendationReason: "推奨は「習慣ログ_年-月.csv」（月ごとに並ぶ）",
                askedAt: asked
            ),
            Question(
                id: "Q4",
                title: "書き出しの形式",
                why: "ほかのアプリでの開きやすさと、実装の量が変わります",
                options: [
                    Self.option("a", "JSON", "ほかのアプリに取り込みやすい"),
                    Self.option("b", "PDF", "印刷向け。表の組み版が要る"),
                    Self.option("c", "CSV", "表計算で開ける。実装は最小"),
                    Self.option("d", "CSV と PDF", "両方を作る。実装は 2 倍")
                ],
                recommendedOptionID: "c",
                recommendationReason: "目的（表計算で集計する）にいちばん合う",
                askedAt: asked
            )
        ]
    }

    static func option(_ id: String, _ label: String, _ effect: String) -> Question.Option {
        Question.Option(id: id, label: label, effect: effect)
    }
}
