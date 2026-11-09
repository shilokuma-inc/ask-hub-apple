import Foundation

/// デモのデータ（架空のアプリと Mac）。Preview・デモモード・UI テスト・スクショで使う。
///
/// リポジトリは public なので、実在のリポジトリや個人の情報は入れない
enum DemoScenario: String, CaseIterable {
    /// 段階ごとの状態をひととおり含む
    case standard
    /// 人の出番が無く、機械だけが動いている
    case quiet
    /// 一度も読めない（取得の失敗の画面）
    case failing
    /// 一部の取得元だけ読めない
    case partial
    /// 標準の場面に、1 つの epic に収まらない依頼（分け方の判断の待ち）を足す
    case tooLarge
    /// 開始した後の段取り（作業場所の用意・実装中・実装の途中の質問・直し）を並べる
    case started

    /// 機械の反応までの秒数を決める UserDefaults のキー（UI テストは起動引数 `-demoReactionDelay 0` で渡す）
    static let reactionDelayKey = "demoReactionDelay"
    /// 送るのにかかる秒数を決める UserDefaults のキー（送っている間の画面を撮るときに、起動引数 `-demoSendDelay 3` で渡す）
    static let sendDelayKey = "demoSendDelay"
    /// 司令塔が送った意図を受け取るまでの秒数を決める UserDefaults のキー（同期待ちの画面を撮るときに、起動引数 `-demoReceiptDelay 3600` で渡す。
    /// 司令塔の生きている印が古い（止まっている）場面になる）
    static let receiptDelayKey = "demoReceiptDelay"
    /// 司令塔が送った意図を断るかを決める UserDefaults のキー（断られたときの画面を撮るときに、起動引数 `-demoRejectIntents YES` で渡す。
    /// 送った意図は受け取り待ちの間だけ送った結果の形で出し、断ったら元に戻る）
    static let rejectsIntentsKey = "demoRejectIntents"
    /// 司令塔の受け取りを待ったまま、受け取りが遅いと知らせるまでの秒数を決める UserDefaults のキー（起動引数 `-demoStallAfter 5` で渡す）
    static let stallThresholdKey = "demoStallAfter"

    /// 起動引数で渡した秒数を読む。起動引数の値は文字列で入る（`object(forKey:) as? Double` では読めない）ので、文字列から読む。
    /// 数でない・有限でない（`nan`・`inf`）値は、渡していないものとする
    static func seconds(forKey key: String, in defaults: UserDefaults) -> TimeInterval? {
        guard let seconds = defaults.string(forKey: key).flatMap(Double.init), seconds.isFinite else {
            return nil
        }
        return seconds
    }

    func snapshot(now: Date) -> ClientSnapshot {
        let data = DemoData(now: now)
        switch self {
        case .standard, .failing:
            return data.standard()

        case .quiet:
            return data.quiet()

        case .partial:
            var snapshot = data.standard()
            snapshot.sourceFailures = [SourceFailure(source: "状態リポジトリ", message: "応答がありませんでした（503）")]
            return snapshot

        case .tooLarge:
            var snapshot = data.standard()
            snapshot.epics.insert(data.splitEpic(), at: 0)
            return snapshot

        case .started:
            return data.started()
        }
    }
}

/// デモのデータの組み立て。時刻は `now` からの相対で決める
struct DemoData {
    let now: Date

    static let owner = "demo-studio"

    func ago(minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    func later(minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    func standard() -> ClientSnapshot {
        ClientSnapshot(
            repositories: Self.repositories,
            candidateRepositories: Self.candidates,
            epics: [
                recipeEpic(),
                habitEpic(),
                shoppingEpic(),
                rainEpic(),
                budgetEpic(),
                tsundokuEpic(),
                kajiEpic(),
                habitDoneEpic()
            ],
            macs: macs(),
            fetchedAt: now,
            sourceFailures: []
        )
    }

    func quiet() -> ClientSnapshot {
        var kaji = kajiEpic()
        kaji.macID = Self.macBookProID
        kaji.startTask(at: 4, attempt: 1, date: ago(minutes: 12))
        kaji.activities[0].worker?.heartbeatAt = ago(minutes: 3)
        var tsundoku = tsundokuEpic()
        tsundoku.finalReview?.mergePolicy = .automatic
        tsundoku.finalReview?.decisions = []
        tsundoku.finalReview?.checks.ci = .running
        tsundoku.activities = [EpicActivity(kind: .waitingForCI(taskID: nil), since: ago(minutes: 4))]
        var macs = macs().filter { $0.id != Self.macBookAirID }
        for index in macs.indices {
            macs[index].cleanupCandidates = []
            macs[index].tokens = tokens(githubDays: 82, claudeDays: 301)
            macs[index].claudeVersion = Self.claudeVersion
            macs[index].commanderClaudeVersion = nil
        }
        return ClientSnapshot(
            repositories: Self.repositories,
            candidateRepositories: Self.candidates,
            epics: [kaji, shoppingEpic(), tsundoku],
            macs: macs,
            fetchedAt: now,
            sourceFailures: []
        )
    }
}

// MARK: - 開始した後の段取り

extension DemoData {
    /// 標準の場面の、開始を待っていた epic を開始し、止まっていた epic を直しの途中にする
    func started() -> ClientSnapshot {
        var snapshot = standard()
        snapshot.updateEpic("budget-limit") { epic in
            epic.stage = .implementing
            epic.macID = Self.macBookProID
            epic.tasks = (epic.goal?.tasks ?? []).enumerated().map { index, task in
                EpicTask(id: "budget-t\(index + 1)", number: index + 1, title: task.title, state: .pending)
            }
            epic.workspace = .preparing
            let worker = EpicActivity.Worker(macID: Self.macBookProID, heartbeatAt: ago(minutes: 1))
            epic.activities = [EpicActivity(kind: .step(.prepareWorkspace, .running(attempt: 1)), since: ago(minutes: 2), worker: worker)]
            epic.log("MacBook Pro 14 で開始しました", at: ago(minutes: 3))
        }
        snapshot.updateEpic("kaji-notify") { epic in
            epic.macID = Self.macBookProID
            let fixing = EpicTask.Phase.fixing(pullRequest: 15, round: 1, reason: .checks)
            epic.tasks[4].state = .inProgress(fixing)
            let worker = EpicActivity.Worker(macID: Self.macBookProID, heartbeatAt: ago(minutes: 4))
            let step = WorkStep.task("kaji-t5", fixing)
            epic.activities = [EpicActivity(kind: .step(step, .running(attempt: 1)), since: ago(minutes: 9), worker: worker)]
            epic.log("MacBook Pro 14 に引き継ぎました", at: ago(minutes: 30))
            epic.log("タスク 5 の子 PR #15 の CI が通らないので直します", at: ago(minutes: 10))
        }
        // 買い物リストの並べ替えは、タスク 2 の実装の途中で Claude が人に聞いた（答えるまで止めて待つ）
        snapshot.updateEpic("recipe-shopping") { epic in
            epic.tasks[1].state = .inProgress(.waitingForAnswer(question: "Q1", pullRequest: nil))
            epic.activities = []
            epic.questions = [shoppingQuestion()]
            epic.log("タスク 2 の実装の途中で、Claude が Q1 を聞きました。答えるまで止めて待ちます", at: ago(minutes: 5))
        }
        snapshot.updateMac(Self.macMiniID) { mac in
            mac.jobs.removeAll { $0.epicID == "recipe-shopping" }
        }
        // 家事の分担の通知は MacBook Air から引き継いだので、MacBook Air にはジョブを残さない
        snapshot.updateMac(Self.macBookAirID) { mac in
            mac.jobs.removeAll { $0.epicID == "kaji-notify" }
        }
        snapshot.updateMac(Self.macBookProID) { mac in
            mac.jobs = [
                Mac.Job(id: "job-budget", title: "月の上限の通知: 作業場所の用意", epicID: "budget-limit", startedAt: ago(minutes: 2)),
                Mac.Job(id: "job-kaji", title: "家事の分担の通知: タスク 5 の直し", epicID: "kaji-notify", startedAt: ago(minutes: 9))
            ]
        }
        return snapshot
    }

    /// 実装の途中の質問（買い物リストの並べ替えのタスク 2）
    private func shoppingQuestion() -> Question {
        Question(
            id: "Q1",
            title: "売り場の並びを変えられるようにするか",
            why: "店ごとに売り場の順が違う。決めた並びで固定するか、人が並べ替えられるようにするかで、保存するものが変わる",
            options: [
                Question.Option(id: "決めた並びで固定", label: "決めた並びで固定", effect: "野菜・肉・魚・調味料の順にする。設定の画面は作らない"),
                Question.Option(id: "人が並べ替えられる", label: "人が並べ替えられる", effect: "設定に並べ替えの画面を足し、順を端末に保存する"),
                Question.Option(id: "店ごとに並びを持つ", label: "店ごとに並びを持つ", effect: "店を登録する画面も要る。このタスクの範囲を超える")
            ],
            recommendedOptionID: "決めた並びで固定",
            recommendationReason: "ゴールの「やらないこと」に設定の追加があるため。並べ替えは後で足せる",
            askedAt: ago(minutes: 5),
            during: .task(number: 2, title: "一覧に並べ替えのボタン")
        )
    }
}

// MARK: - リポジトリと Mac

extension DemoData {
    static let macMiniID = "mac-mini"
    static let macBookProID = "macbook-pro"
    static let macBookAirID = "macbook-air"

    static func repositoryID(_ name: String) -> TargetRepository.ID {
        "\(owner)/\(name)".lowercased()
    }

    static let repositories: [TargetRepository] = [
        repository("habit-ios", "習慣ログ", "checklist", .green, lastMac: macMiniID),
        repository("recipe-apple", "献立メモ", "fork.knife", .orange, lastMac: macBookProID),
        repository("rain-ios", "雨雲チェック", "cloud.rain.fill", .blue, lastMac: macBookProID),
        // ゴールを確かめて開始する epic がある。開始のときは前回の MacBook Pro を選んである
        repository("pocket-budget-ios", "おこづかい帳", "yensign.circle.fill", .purple, lastMac: macBookProID),
        repository("tsundoku-ios", "積読リスト", "books.vertical.fill", .teal, lastMac: macMiniID),
        // 前回の Mac（MacBook Air）がオフラインなので、開始のときは何も選んでいない
        repository("kaji-share-ios", "家事シェア", "house.fill", .pink, lastMac: macBookAirID)
    ]

    static let candidates: [TargetRepository] = [
        TargetRepository(owner: owner, name: "memo-widget-ios", appName: "メモウィジェット", icon: .monogram),
        TargetRepository(owner: owner, name: "sleep-log-apple", appName: "睡眠ログ", icon: .monogram),
        TargetRepository(owner: owner, name: "plant-water-ios", appName: "水やり当番", icon: .monogram)
    ]

    private static func repository(
        _ name: String,
        _ appName: String,
        _ symbol: String,
        _ tint: IconTint,
        lastMac: Mac.ID?
    ) -> TargetRepository {
        TargetRepository(owner: owner, name: name, appName: appName, icon: .symbol(symbol, tint), lastMacID: lastMac)
    }

    func macs() -> [Mac] {
        [macMini(), macBookPro(), macBookAir()]
    }

    private func macMini() -> Mac {
        Mac(
            id: Self.macMiniID,
            name: "Mac mini",
            model: "Mac mini（M2）",
            role: .commandCenter,
            residency: .always,
            connection: .online(lastSeen: ago(minutes: 1)),
            freeBytes: 41 * Self.gigabyte,
            totalBytes: 256 * Self.gigabyte,
            load: 0.42,
            version: "1.0.0",
            versionMatches: true,
            jobs: [
                Mac.Job(id: "job-explain", title: "献立メモ: Q4 の説明を書いています", epicID: "recipe-weekly", startedAt: ago(minutes: 6)),
                Mac.Job(id: "job-shopping", title: "買い物リストの並べ替え: タスク 2 の子 PR のレビュー", epicID: "recipe-shopping", startedAt: ago(minutes: 6))
            ],
            refusalReason: nil,
            selfChecks: selfChecks(free: "41 GB"),
            tokens: tokens(githubDays: 82, claudeDays: 301),
            claudeVersion: Self.claudeVersion,
            cleanupCandidates: [
                CleanupCandidate(id: "c1", kind: .simulator, name: "iPhone 16 Pro（手で作成）", bytes: 6_400 * Self.megabyte, caution: nil),
                CleanupCandidate(id: "c2", kind: .clone, name: "~/Desktop/ios/old-habit-ios", bytes: 2_100 * Self.megabyte, caution: nil),
                CleanupCandidate(
                    id: "c3",
                    kind: .clone,
                    name: "~/work/rain-ios-copy",
                    bytes: 1_200 * Self.megabyte,
                    caution: "未 push のコミットが 2 つあります"
                )
            ]
        )
    }

    private func macBookPro() -> Mac {
        Mac(
            id: Self.macBookProID,
            name: "MacBook Pro 14",
            model: "MacBook Pro 14 インチ（M4 Pro）",
            role: .worker,
            residency: .whileOpen,
            connection: .online(lastSeen: ago(minutes: 2)),
            freeBytes: 412 * Self.gigabyte,
            totalBytes: 1_000 * Self.gigabyte,
            load: 0.18,
            version: "1.0.0",
            versionMatches: true,
            jobs: [],
            refusalReason: nil,
            selfChecks: selfChecks(free: "412 GB"),
            // GitHub のトークンの期限が近く、Claude Code を入れ替えていない
            tokens: tokens(githubDays: 10, claudeDays: 290),
            claudeVersion: "2.1.316",
            commanderClaudeVersion: Self.claudeVersion,
            cleanupCandidates: []
        )
    }

    private func macBookAir() -> Mac {
        Mac(
            id: Self.macBookAirID,
            name: "MacBook Air（社用）",
            model: "MacBook Air 13 インチ（M3）",
            role: .worker,
            residency: .manual,
            connection: .offline(since: ago(minutes: 185)),
            freeBytes: 23 * Self.gigabyte,
            totalBytes: 512 * Self.gigabyte,
            load: 0,
            version: "1.0.0",
            versionMatches: true,
            jobs: [Mac.Job(id: "job-kaji", title: "家事シェア: タスク 5 の実装", epicID: "kaji-notify", startedAt: ago(minutes: 200))],
            refusalReason: "空き容量が 30 GB を下回っています",
            selfChecks: selfChecks(free: "23 GB", lowDisk: true),
            tokens: tokens(githubDays: 82, claudeDays: 301),
            claudeVersion: Self.claudeVersion,
            cleanupCandidates: []
        )
    }

    private func selfChecks(free: String, lowDisk: Bool = false) -> [Mac.SelfCheck] {
        [
            Mac.SelfCheck(name: "Keychain", isOK: true, detail: "読めます"),
            Mac.SelfCheck(name: "空き容量", isOK: !lowDisk, detail: free)
        ]
    }

    /// 司令塔の Claude Code の版
    static let claudeVersion = "2.1.320"

    /// 期限まで指定した日数のトークン（GitHub は持ち主ごと）
    func tokens(githubDays: Double, claudeDays: Double) -> [MacToken] {
        let day: TimeInterval = 24 * 60 * 60
        return [
            MacToken(kind: .github(owner: Self.owner), state: .ok, expiresAt: now.addingTimeInterval(githubDays * day - 60)),
            MacToken(kind: .claude, state: .ok, expiresAt: now.addingTimeInterval(claudeDays * day - 60))
        ]
    }

    static let megabyte: Int64 = 1_000_000
    static let gigabyte: Int64 = 1_000_000_000
}
