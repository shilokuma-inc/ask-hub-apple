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

    /// 機械の反応までの秒数を決める UserDefaults のキー（UI テストは起動引数 `-demoReactionDelay 0` で渡す）
    static let reactionDelayKey = "demoReactionDelay"

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
        kaji.activities = [EpicActivity(kind: .implementing(taskID: "kaji-t5", attempt: 1), since: ago(minutes: 12))]
        var tsundoku = tsundokuEpic()
        tsundoku.finalReview?.mergePolicy = .automatic
        tsundoku.finalReview?.decisions = []
        tsundoku.finalReview?.checks.ci = .running
        tsundoku.activities = [EpicActivity(kind: .waitingForCI(taskID: nil), since: ago(minutes: 4))]
        var macs = macs().filter { $0.id != Self.macBookAirID }
        for index in macs.indices {
            macs[index].cleanupCandidates = []
        }
        return ClientSnapshot(
            repositories: Self.repositories,
            candidateRepositories: Self.candidates,
            epics: [kaji, tsundoku],
            macs: macs,
            fetchedAt: now,
            sourceFailures: []
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
        repository("habit-ios", "習慣ログ", "checklist", .green, macs: [macMiniID, macBookProID, macBookAirID]),
        repository("recipe-apple", "献立メモ", "fork.knife", .orange, macs: [macMiniID, macBookProID]),
        repository("rain-ios", "雨雲チェック", "cloud.rain.fill", .blue, macs: [macMiniID, macBookProID]),
        repository("pocket-budget-ios", "おこづかい帳", "yensign.circle.fill", .purple, macs: [macMiniID, macBookProID, macBookAirID]),
        repository("tsundoku-ios", "積読リスト", "books.vertical.fill", .teal, macs: [macBookProID, macMiniID]),
        // 技術検証のリポジトリ。実装は社用の Mac でだけ回す
        repository("kaji-share-ios", "家事シェア", "house.fill", .pink, macs: [macBookAirID])
    ]

    static let candidates: [TargetRepository] = [
        TargetRepository(owner: owner, name: "memo-widget-ios", appName: "メモウィジェット", icon: .monogram, allowedMacIDs: []),
        TargetRepository(owner: owner, name: "sleep-log-apple", appName: "睡眠ログ", icon: .monogram, allowedMacIDs: []),
        TargetRepository(owner: owner, name: "plant-water-ios", appName: "水やり当番", icon: .monogram, allowedMacIDs: [])
    ]

    private static func repository(
        _ name: String,
        _ appName: String,
        _ symbol: String,
        _ tint: IconTint,
        macs: [Mac.ID]
    ) -> TargetRepository {
        TargetRepository(owner: owner, name: name, appName: appName, icon: .symbol(symbol, tint), allowedMacIDs: macs)
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
            contract: .personal,
            connection: .online(lastSeen: ago(minutes: 1)),
            freeBytes: 41 * Self.gigabyte,
            totalBytes: 256 * Self.gigabyte,
            load: 0.42,
            version: "1.0.0",
            versionMatches: true,
            jobs: [Mac.Job(id: "job-explain", title: "献立メモ: Q4 の説明を書いています", epicID: "recipe-weekly", startedAt: ago(minutes: 6))],
            refusalReason: nil,
            selfChecks: selfChecks(free: "41 GB"),
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
            contract: .personal,
            connection: .online(lastSeen: ago(minutes: 2)),
            freeBytes: 412 * Self.gigabyte,
            totalBytes: 1_000 * Self.gigabyte,
            load: 0.18,
            version: "1.0.0",
            versionMatches: true,
            jobs: [],
            refusalReason: nil,
            selfChecks: selfChecks(free: "412 GB"),
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
            contract: .company,
            connection: .offline(since: ago(minutes: 185)),
            freeBytes: 23 * Self.gigabyte,
            totalBytes: 512 * Self.gigabyte,
            load: 0,
            version: "1.0.0",
            versionMatches: true,
            jobs: [Mac.Job(id: "job-kaji", title: "家事シェア: タスク 5 の実装", epicID: "kaji-notify", startedAt: ago(minutes: 200))],
            refusalReason: "空き容量が 30 GB を下回っています",
            selfChecks: selfChecks(free: "23 GB", lowDisk: true),
            cleanupCandidates: []
        )
    }

    private func selfChecks(free: String, lowDisk: Bool = false) -> [Mac.SelfCheck] {
        [
            Mac.SelfCheck(name: "GitHub のトークン", isOK: true, detail: "あと 82 日"),
            Mac.SelfCheck(name: "Claude の setup-token", isOK: true, detail: "あと 301 日"),
            Mac.SelfCheck(name: "Keychain", isOK: true, detail: "読めます"),
            Mac.SelfCheck(name: "空き容量", isOK: !lowDisk, detail: free)
        ]
    }

    static let megabyte: Int64 = 1_000_000
    static let gigabyte: Int64 = 1_000_000_000
}
