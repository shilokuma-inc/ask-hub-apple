import Foundation

// MARK: - ゴール・実装の段階の epic

extension DemoData {
    /// 雨雲チェック: 実装中に失敗が人に渡され、人がする作業もある
    func rainEpic() -> Epic {
        Epic(
            id: "rain-draft",
            title: "オフラインの下書き",
            repositoryID: Self.repositoryID("rain-ios"),
            request: EpicRequest(
                summary: "電波が無いところでも地点のメモを書いておきたい",
                body: "山の中で書いたメモを、電波が戻ったら送ってほしい。ウィジェットからも下書きを見たい。",
                requestedAt: ago(minutes: 60 * 26),
                source: .app,
                attachmentCount: 0
            ),
            stage: .implementing,
            questions: [],
            goal: nil,
            humanTasks: [rainAppGroupTask()],
            tasks: [
                EpicTask(id: "rain-t1", number: 1, title: "下書きのモデル", state: .done(pullRequest: 41)),
                EpicTask(id: "rain-t2", number: 2, title: "一覧に下書きを出す", state: .done(pullRequest: 42)),
                EpicTask(id: "rain-t3", number: 3, title: "下書きの保存", state: .failed),
                EpicTask(id: "rain-t4", number: 4, title: "通信の切れ目を検知する", state: .locked(reason: "App Group の登録（人がする作業）待ち")),
                EpicTask(id: "rain-t5", number: 5, title: "通信が戻ったら送る", state: .pending),
                EpicTask(id: "rain-t6", number: 6, title: "下書きを消す操作", state: .pending),
                EpicTask(id: "rain-t7", number: 7, title: "ウィジェットに下書きを出す", state: .pending)
            ],
            macID: Self.macBookProID,
            activities: [],
            blocker: rainBlocker(),
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 26), text: "依頼しました"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 20), text: "MacBook Pro 14 で開始しました"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 3), text: "タスク 1 をマージしました（#41）"),
                Epic.HistoryEntry(date: ago(minutes: 70), text: "タスク 2 をマージしました（#42）"),
                Epic.HistoryEntry(date: ago(minutes: 25), text: "タスク 3 の試行 3 が失敗しました（ビルド・テスト）", isFailure: true)
            ],
            updatedAt: ago(minutes: 25),
            workspace: .ready(branch: "askhub/rain-draft")
        )
    }

    private func rainAppGroupTask() -> HumanTask {
        HumanTask(
            id: "ht-app-group",
            title: "App Group を登録する",
            why: "下書きをウィジェットと共有するため。App Group は Apple Developer の Web でしか登録できません",
            steps: [
                HumanTask.Step(text: "Apple Developer の Identifiers を開き、種類を App Groups にする", copyableValue: nil),
                HumanTask.Step(text: "＋ を押し、Identifier に次の値を入れて登録する", copyableValue: "group.demo-studio.rain"),
                HumanTask.Step(text: "App ID の一覧で次のものを開き、App Groups にチェックを入れて上の値を選ぶ", copyableValue: "demo-studio.rain-ios")
            ],
            links: [
                HumanTask.Link(
                    title: "Apple Developer の Identifiers",
                    url: URL(string: "https://developer.apple.com/account/resources/identifiers/list")!
                )
            ],
            deliverable: .none,
            blocksTaskIDs: ["rain-t4"],
            state: .todo
        )
    }

    private func rainBlocker() -> Blocker {
        let mac = "MacBook Pro 14"
        return Blocker(
            category: .build,
            title: "ビルドが通りません",
            summary: "タスク 3「下書きの保存」を 3 回直させましたが、通りません",
            logExcerpt: """
            DraftStore.swift:42:17: error: cannot find 'DraftCache' in scope
                    let cache = DraftCache(directory: groupURL)
                                ^~~~~~~~~~
            """,
            attempts: [
                Blocker.Attempt(
                    number: 1,
                    macName: mac,
                    startedAt: ago(minutes: 58),
                    endedAt: ago(minutes: 49),
                    outcome: "DraftCache の型が見つからない"
                ),
                Blocker.Attempt(
                    number: 2,
                    macName: mac,
                    startedAt: ago(minutes: 45),
                    endedAt: ago(minutes: 36),
                    outcome: "App Group の場所を読む処理を足したが、同じエラー"
                ),
                Blocker.Attempt(
                    number: 3,
                    macName: mac,
                    startedAt: ago(minutes: 33),
                    endedAt: ago(minutes: 25),
                    outcome: "DraftCache はタスク 4（App Group の登録の後）で作る前提だった"
                )
            ],
            occurredAt: ago(minutes: 25),
            actions: [.fixWithInstruction, .retry, .handOver, .pause, .discard]
        )
    }

    /// おこづかい帳: ゴールを確かめて開始を押す
    func budgetEpic() -> Epic {
        Epic(
            id: "budget-limit",
            title: "月の上限の通知",
            repositoryID: Self.repositoryID("pocket-budget-ios"),
            request: EpicRequest(
                summary: "使いすぎたら知らせてほしい",
                body: "月の予算を決めて、近づいたら通知してほしい。",
                requestedAt: ago(minutes: 60 * 5),
                source: .app,
                attachmentCount: 0
            ),
            stage: .goal,
            questions: budgetQuestions(),
            goal: budgetGoal(),
            humanTasks: [],
            tasks: [],
            macID: nil,
            activities: [],
            blocker: nil,
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 5), text: "依頼しました"),
                Epic.HistoryEntry(date: ago(minutes: 75), text: "質問にすべて回答しました"),
                Epic.HistoryEntry(date: ago(minutes: 60), text: "着手前の確認が終わり、ゴールを作りました")
            ],
            updatedAt: ago(minutes: 60)
        )
    }

    private func budgetQuestions() -> [Question] {
        let asked = ago(minutes: 60 * 4)
        let answered = ago(minutes: 75)
        return [
            Question(
                id: "Q1",
                title: "上限の決め方",
                why: "設定画面と保存のデータが変わります",
                options: [Self.option("a", "月ごとに 1 つ", "設定は 1 項目"), Self.option("b", "カテゴリごと", "カテゴリの数だけ項目が要る")],
                recommendedOptionID: "a",
                recommendationReason: "依頼の範囲に合う",
                state: .answered(Question.Response(optionID: "a", note: "", answeredAt: answered)),
                askedAt: asked
            ),
            Question(
                id: "Q2",
                title: "通知の文言",
                why: "通知の文の作りが変わります",
                options: [Self.option("a", "割合と残りの金額", "例: 8 割に達しました（残り 6,000 円）"), Self.option("b", "割合だけ", "短い")],
                recommendedOptionID: "a",
                recommendationReason: "次に使える金額がすぐ分かる",
                state: .answered(Question.Response(optionID: "a", note: "", answeredAt: answered)),
                askedAt: asked
            ),
            Question(
                id: "Q3",
                title: "知らせる時",
                why: "通知の回数と予約の作りが変わります",
                options: [Self.option("a", "8 割と 10 割", "2 回だけ"), Self.option("b", "5 割ごと", "回数が増える")],
                recommendedOptionID: "a",
                recommendationReason: "通知が多すぎない",
                state: .answered(Question.Response(optionID: "a", note: "", answeredAt: answered)),
                askedAt: asked
            )
        ]
    }

    private func budgetGoal() -> Goal {
        Goal(
            version: 1,
            summary: "その月の支出が上限の 8 割と 10 割に達したら通知する。上限は設定画面で月ごとに 1 つ決める",
            decided: [
                Goal.Point(text: "上限は月ごとに 1 つ決める", questionID: "Q1"),
                Goal.Point(text: "通知の文言は、割合と残りの金額にする", questionID: "Q2"),
                Goal.Point(text: "通知は 8 割と 10 割の 2 回", questionID: "Q3")
            ],
            notDoing: ["カテゴリごとの上限", "週ごとの上限", "通知の時刻の設定"],
            doneCriteria: [
                "上限を決めると、8 割と 10 割で 1 回ずつ通知が届く",
                "上限を決めていない月は通知しない",
                "ちょうど 8 割の金額の境目を Unit テストで確かめる"
            ],
            tasks: [
                Goal.PlannedTask(title: "上限のモデルと保存", humanTaskID: nil),
                Goal.PlannedTask(title: "設定画面に上限の項目を足す", humanTaskID: nil),
                Goal.PlannedTask(title: "支出が変わったら割合を計算する", humanTaskID: nil),
                Goal.PlannedTask(title: "通知の予約と取り消し", humanTaskID: nil),
                Goal.PlannedTask(title: "デモのデータに上限を足す", humanTaskID: nil)
            ],
            revisionRequest: nil
        )
    }

    /// 家事シェア: 社用の Mac が閉じていて一時停止している
    func kajiEpic() -> Epic {
        let titles = ["当番のモデル", "当番の一覧", "当番を回す処理", "通知の許可", "当番の通知", "通知から開く画面", "設定に通知の項目", "デモのデータ"]
        let tasks = titles.enumerated().map { index, title in
            let number = index + 1
            let state: EpicTask.State = switch number {
            case ...4: .done(pullRequest: 10 + number)
            case 5: .inProgress(.implementing)
            default: .pending
            }
            return EpicTask(id: "kaji-t\(number)", number: number, title: title, state: state)
        }
        return Epic(
            id: "kaji-notify",
            title: "家事の分担の通知",
            repositoryID: Self.repositoryID("kaji-share-ios"),
            request: EpicRequest(
                summary: "自分の番になった家事を知らせてほしい",
                body: "当番が回ってきたら、その人にだけ通知したい。",
                requestedAt: ago(minutes: 60 * 30),
                source: .app,
                attachmentCount: 0
            ),
            stage: .implementing,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: tasks,
            macID: Self.macBookAirID,
            activities: [EpicActivity(kind: .paused(macID: Self.macBookAirID, since: ago(minutes: 185)), since: ago(minutes: 185))],
            blocker: nil,
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 30), text: "依頼しました"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 8), text: "MacBook Air（社用）で開始しました"),
                Epic.HistoryEntry(date: ago(minutes: 200), text: "タスク 4 をマージしました（#14）"),
                Epic.HistoryEntry(date: ago(minutes: 185), text: "MacBook Air（社用）がオフラインになり、一時停止しました")
            ],
            updatedAt: ago(minutes: 185),
            workspace: .ready(branch: "askhub/kaji-notify")
        )
    }

    /// 献立メモ: Mac mini で回していて、タスク 2 の子 PR のチェックを待ってレビューしている
    func shoppingEpic() -> Epic {
        let titles = ["並べ替えのモデル", "一覧に並べ替えのボタン", "並べ替えを保存する", "デモのデータに並べ替えを足す"]
        let tasks = titles.enumerated().map { index, title in
            let state: EpicTask.State = switch index {
            case 0: .done(pullRequest: 61)
            case 1: .inProgress(.reviewing(pullRequest: 62))
            default: .pending
            }
            return EpicTask(id: "shopping-t\(index + 1)", number: index + 1, title: title, state: state)
        }
        let worker = EpicActivity.Worker(macID: Self.macMiniID, heartbeatAt: ago(minutes: 2))
        let reviewing = WorkStep.task("shopping-t2", .reviewing(pullRequest: 62))
        return Epic(
            id: "recipe-shopping",
            title: "買い物リストの並べ替え",
            repositoryID: Self.repositoryID("recipe-apple"),
            request: EpicRequest(
                summary: "買い物リストを売り場の順に並べたい",
                body: "スーパーを回る順に、野菜・肉・調味料のようにまとめて並べ替えたい。",
                requestedAt: ago(minutes: 60 * 9),
                source: .app,
                attachmentCount: 0
            ),
            stage: .implementing,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: tasks,
            macID: Self.macMiniID,
            activities: [EpicActivity(kind: .step(reviewing, .running(attempt: 1)), since: ago(minutes: 6), worker: worker)],
            blocker: nil,
            finalReview: nil,
            history: [
                Epic.HistoryEntry(date: ago(minutes: 60 * 9), text: "依頼しました"),
                Epic.HistoryEntry(date: ago(minutes: 60 * 2), text: "Mac mini で開始しました"),
                Epic.HistoryEntry(date: ago(minutes: 118), text: "作業ブランチ askhub/recipe-shopping を作りました"),
                Epic.HistoryEntry(date: ago(minutes: 40), text: "タスク 1 をマージしました（#61）")
            ],
            updatedAt: ago(minutes: 6),
            workspace: .ready(branch: "askhub/recipe-shopping")
        )
    }
}
