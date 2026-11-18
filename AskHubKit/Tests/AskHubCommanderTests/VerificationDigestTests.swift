@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 止めないもの（実機確認）を、決めた時刻にまとめて知らせる
struct VerificationDigestTests {
    static let repo = NotifierTests.repo
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-11-04 11:00（東京）
    static let start = NotifierTests.now

    let base = NotifierTests()

    func notifier(_ store: InMemoryStateStore, sender: RecordingPushSender) -> Notifier {
        let clock = base.clock
        let context = CommanderContext(store: store, mac: EpicHandlersTests.commander) { clock.now }
        let settings = Notifier.Settings(timeZone: Self.tokyo, verificationHours: [9, 13, 18])
        return Notifier(context: context, sender: sender, settings: settings, log: { _ in })
    }

    /// `minutes` 分前（11:00 から）にマージした epic と、完了の条件 2 件のゴールを置く。`answered` は答えた項目
    func merged(
        _ number: Int,
        title: String,
        minutes: Double,
        answered: [String] = [],
        in store: InMemoryStateStore
    ) async throws -> EpicFile {
        let id = ULID(rawValue: "01JCEP1D00000000000000000\(number)")!
        let at = Timestamp(Self.start.addingTimeInterval(-minutes * 60))
        var epic = EpicFile(id: id, repo: Self.repo, title: title, stage: .merged, createdAt: at, updatedAt: at)
        epic.merge = .init(commit: String(repeating: "e", count: 40), at: at)
        try await base.put(epic, at: StatePath.epic(Self.repo, id), in: store)
        let goal = GoalFile(version: 1, summary: "要約", doneWhen: ["一覧に出る", "並べ替えられる"], tasks: [.init(id: "t1", title: "タスク")])
        try await base.put(goal, at: StatePath.goal(Self.repo, id), in: store)
        if !answered.isEmpty {
            let intent = IntentReference(keyId: base.deviceID, nonce: .generate(at: Self.start))
            let answers = VerificationsFile(answers: answered.map { .init(id: $0, result: .confirmed, intent: intent, at: at) })
            try await base.put(answers, at: StatePath.verifications(Self.repo, id), in: store)
        }
        return epic
    }

    @Test func latestSlotIsTodayOrYesterday() {
        let context = CommanderContext(store: InMemoryStateStore(), mac: EpicHandlersTests.commander)
        let digest = VerificationDigest(context: context, hours: [18, 9, 13, 24], timeZone: Self.tokyo)
        let hour = { (offset: Double) in Self.start.addingTimeInterval(offset * 60 * 60) }
        // 11:00 → 9:00、13:00 ちょうど → 13:00、翌日の 8:00 → 前日の 18:00
        #expect(digest.latestSlot(atOrBefore: Self.start) == hour(-2))
        #expect(digest.latestSlot(atOrBefore: hour(2)) == hour(2))
        #expect(digest.latestSlot(atOrBefore: hour(21)) == hour(7))
        #expect(VerificationDigest(context: digest.context, hours: [], timeZone: Self.tokyo).latestSlot(atOrBefore: Self.start) == nil)
    }

    /// 決めた時刻より後にマージした epic は次の時刻まで待ち、時刻が来たら、epic をまたいで 1 通にまとめる。同じ epic は二度送らない。
    /// 答えがすべて揃った epic は知らせない
    @Test func notifiesVerificationsTogetherAtDecidedHours() async throws {
        let store = try await base.storeWithDevice()
        let sender = RecordingPushSender()
        let notifier = notifier(store, sender: sender)
        // 10:00 にマージ（9:00 の後）。11:00 には送らない
        let first = try await merged(1, title: "ランキング", minutes: 60, in: store)
        #expect(try await notifier.notify(epics: [first], jobs: [], trusted: [base.deviceID]).isEmpty)

        // 13:00 に送る。epic が 1 つなら、その epic を開く
        base.clock.advance(minutes: 120)
        let notices = try await notifier.notify(epics: [first], jobs: [], trusted: [base.deviceID])
        #expect(notices.map(\.title) == ["実機で確かめてほしいことがあります"])
        #expect(notices.first?.body == "「ランキング」の 2 件\nTestFlight に上がった版で確かめて、「確認した」か「問題あり」を付けてください")
        #expect(notices.first?.target == ["repo": Self.repo.rawValue, "epic": first.id.rawValue])
        #expect(notices.first?.thread == "verification")
        #expect(try await base.ledger(store) == [VerificationDigest.key(of: first)])
        base.clock.advance(minutes: 1)
        #expect(try await notifier.notify(epics: [first], jobs: [], trusted: [base.deviceID]).isEmpty)

        // 13:30 と 14:00 にマージした epic は、18:00 に 1 通にまとめる（いくつもあれば開く先を持たない）。答えが揃った epic は出さない
        let second = try await merged(2, title: "検索", minutes: -150, answered: ["v1"], in: store)
        let third = try await merged(3, title: "通知", minutes: -180, in: store)
        let done = try await merged(4, title: "設定", minutes: -180, answered: ["v1", "v2"], in: store)
        let epics = [first, second, third, done]
        base.clock.advance(minutes: 120)
        #expect(try await notifier.notify(epics: epics, jobs: [], trusted: [base.deviceID]).isEmpty)
        base.clock.advance(minutes: 179)
        let evening = try await notifier.notify(epics: epics, jobs: [], trusted: [base.deviceID])
        #expect(evening.first?.body == "「検索」の 1 件\n「通知」の 2 件\nTestFlight に上がった版で確かめて、「確認した」か「問題あり」を付けてください")
        #expect(evening.first?.target.isEmpty == true)
        #expect(evening.first?.subtitle == nil)
        #expect(await sender.sent.count == 2)
    }

    /// 止めないものは、進行を止めるものと別の通知にする（同じ周でも、epic の通知に混ぜない）
    @Test func keepsVerificationsSeparateFromBlockers() async throws {
        let store = try await base.storeWithDevice()
        let sender = RecordingPushSender()
        let notifier = notifier(store, sender: sender)
        let finished = try await merged(1, title: "ランキング", minutes: 180, in: store)
        let questions = QuestionsFile(questions: [NotifierTests.question("q1", .open)])
        try await base.put(questions, at: StatePath.questions(Self.repo, NotifierTests.epicID), in: store)
        let notices = try await notifier.notify(epics: [base.epic(.asking), finished], jobs: [], trusted: [base.deviceID])
        #expect(notices.map(\.title) == ["ランキング", "実機で確かめてほしいことがあります"])
        #expect(notices.first?.body == "質問 1 件が回答を待っています")
    }
}
