import AskHubClaude
@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// 送らずに、送ろうとした通知を残す。端末ごとに決めた結果を返す（決めていなければ届いたことにする）
actor RecordingPushSender: PushSender {
    struct Sent: Sendable {
        var notice: PushNotice
        var device: KeyID
    }

    private(set) var sent: [Sent] = []
    private var results: [KeyID: PushDelivery] = [:]

    func answer(_ result: PushDelivery, for device: KeyID) {
        results[device] = result
    }

    func send(_ notice: PushNotice, to device: DeviceFile) async -> PushDelivery {
        sent.append(Sent(notice: notice, device: device.device))
        return results[device.device] ?? .delivered
    }
}

/// 進めたり戻したりできる時計
final class TestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ date: Date) {
        state = OSAllocatedUnfairLock(initialState: date)
    }

    var now: Date { state.withLock { $0 } }

    func advance(minutes: Double) {
        state.withLock { $0 = $0.addingTimeInterval(minutes * 60) }
    }
}

/// 進行を止めるものの通知（拾う・まとめる・二重に送らない・送り直す）
struct NotifierTests {
    static let repo = EpicHandlersTests.repo
    static let laptop = EpicHandlersTests.laptop
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let token = String(repeating: "a1", count: 32)

    let clock = TestClock(NotifierTests.now)
    let device = P256.Signing.PrivateKey()
    var deviceID: KeyID { IntentSignature.keyID(publicKeyDER: device.publicKey.derRepresentation) }

    func notifier(_ store: InMemoryStateStore, sender: RecordingPushSender) -> Notifier {
        let clock = clock
        let context = CommanderContext(store: store, mac: EpicHandlersTests.commander) { clock.now }
        return Notifier(context: context, sender: sender, log: { _ in })
    }

    func put<File: StateFile>(_ file: File, at path: String, in store: InMemoryStateStore) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    func epic(_ stage: EpicStage, id: ULID = NotifierTests.epicID, title: String = "ランキング") -> EpicFile {
        EpicFile(id: id, repo: Self.repo, title: title, stage: stage, createdAt: Timestamp(Self.now), updatedAt: Timestamp(Self.now))
    }

    static func question(_ id: String, _ state: QuestionState, dependsOn: [String] = [], version: Int = 1) -> QuestionsFile.Question {
        QuestionsFile.Question(
            id: id,
            version: version,
            title: "\(id) の題",
            why: "…",
            options: [.init(label: "案1", effect: "…"), .init(label: "案2", effect: "…")],
            recommended: "案1",
            reason: "…",
            dependsOn: dependsOn,
            state: state
        )
    }

    func job(_ number: Int, kind: JobKind = .checkReadiness, mac: MacName? = nil, state: JobState, attempts: Int = 1) -> JobFile {
        JobFile(
            id: ULID(rawValue: "01JCJ0B" + String(format: "%019d", number))!,
            kind: kind,
            repo: Self.repo,
            epic: Self.epicID,
            assignedMac: mac,
            needs: .init(claude: true, build: false),
            state: state,
            attempts: attempts,
            createdAt: Timestamp(Self.now),
            updatedAt: Timestamp(Self.now)
        )
    }

    func mac(_ name: MacName, seenMinutesAgo minutes: Double) -> MacFile {
        MacFile(
            mac: name,
            kind: .resident,
            seenAt: Timestamp(clock.now.addingTimeInterval(-minutes * 60)),
            versions: .init(worker: "1.0.0"),
            diskFreeGB: 100,
            load: 1,
            capacity: .init(claude: 2, build: 1),
            selfCheck: SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        )
    }

    /// 端末の宛先を置いた状態リポジトリ
    func storeWithDevice() async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        try await putDevice(in: store)
        return store
    }

    /// 端末の宛先を置く
    func putDevice(in store: InMemoryStateStore) async throws {
        let file = DeviceFile(
            device: deviceID,
            platform: .ios,
            push: .init(service: .apns, token: Self.token, environment: .production),
            updatedAt: Timestamp(Self.now)
        )
        try await put(file, at: StatePath.device(deviceID), in: store)
    }

    func ledger(_ store: InMemoryStateStore) async throws -> [String] {
        guard let data = await store.data(at: StatePath.notifications) else { return [] }
        return try StateFileCoder.decode(NotificationsFile.self, from: data).sent.map(\.key)
    }

    // MARK: - 要回答

    @Test func notifiesOpenQuestionsOnceInOneNotice() async throws {
        let store = try await storeWithDevice()
        let questions = QuestionsFile(questions: [
            Self.question("q1", .open), Self.question("q2", .open), Self.question("q3", .locked, dependsOn: ["q1"])
        ])
        try await put(questions, at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()
        let notifier = notifier(store, sender: sender)
        let epics = [epic(.asking)]

        let notices = try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID])
        let base = "question/\(Self.repo)/\(Self.epicID)"
        #expect(notices.map(\.keys) == [["\(base)/q1/1/0", "\(base)/q2/1/0"]])
        #expect(notices.first?.title == "ランキング")
        #expect(notices.first?.subtitle == Self.repo.rawValue)
        #expect(notices.first?.body == "質問 2 件が回答を待っています")
        #expect(notices.first?.target == ["repo": Self.repo.rawValue, "epic": Self.epicID.rawValue])
        #expect(await sender.sent.map(\.device) == [deviceID])
        #expect(try await ledger(store) == ["\(base)/q1/1/0", "\(base)/q2/1/0"])

        // 同じ出来事は、次の周に送らない
        clock.advance(minutes: 1)
        #expect(try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID]).isEmpty)
        #expect(await sender.sent.count == 1)

        // 説明ができた質問（説明の数が変わった）と、ロックが外れた質問だけを、もう一度知らせる
        var next = questions
        let asked = IntentReference(keyId: deviceID, nonce: .generate(at: Self.now))
        next.questions[1].explanations = [.init(asked: asked, note: "", text: "説明", at: Timestamp(Self.now))]
        next.questions[2].state = .open
        next.questions[0].state = .answered
        let answered = IntentReference(keyId: deviceID, nonce: .generate(at: Self.now))
        next.questions[0].answer = .init(choice: "案1", intent: answered, at: Timestamp(Self.now))
        try await put(next, at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let again = try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID])
        #expect(again.map(\.keys) == [["\(base)/q2/1/1", "\(base)/q3/1/0"]])
    }

    @Test func notifiesGoalSplitAndJobsWaitingForHuman() async throws {
        let store = try await storeWithDevice()
        let goal = GoalFile(version: 2, summary: "要約", doneWhen: ["完了"], tasks: [.init(id: "t1", title: "タスク")])
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID), in: store)
        let other = ULID(rawValue: "01JCEP1C000000000000000002")!
        let readiness = ReadinessFile(
            version: 3,
            verdict: .tooLarge,
            reason: "大きい",
            split: [.init(title: "A", summary: "a")],
            round: 1,
            checkedAt: Timestamp(Self.now)
        )
        try await put(readiness, at: StatePath.readiness(Self.repo, other), in: store)
        let sender = RecordingPushSender()
        let jobs = [
            job(1, state: .waitingHuman, attempts: 4),
            job(2, kind: .reviseGoal, state: .waitingHuman, attempts: 2),
            job(3, state: .succeeded)
        ]
        let epics = [epic(.awaitingStart), epic(.awaitingSplit, id: other, title: "分ける")]

        let notices = try await notifier(store, sender: sender).notify(epics: epics, jobs: jobs, trusted: [deviceID])
        #expect(notices.map(\.body) == [
            "ゴールを直しました。確かめて開始してください\n着手前の確認が止まり、判断を待っています\nゴールの修正が止まり、判断を待っています",
            "1 つの epic に収まりません。分け方を選んでください"
        ])
        #expect(notices.first?.keys == [
            "start/\(Self.repo)/\(Self.epicID)/2",
            "job/\(Self.repo)/\(Self.epicID)/\(jobs[0].id)/4",
            "job/\(Self.repo)/\(Self.epicID)/\(jobs[1].id)/2"
        ])
        #expect(notices.last?.keys == ["split/\(Self.repo)/\(other)/3"])
        #expect(notices.last?.thread == other.rawValue)
    }

    // MARK: - ワーカーがオフライン

    @Test func notifiesOfflineMacOnlyWhileItHoldsJobsForAnHour() async throws {
        let store = try await storeWithDevice()
        let sender = RecordingPushSender()
        let notifier = notifier(store, sender: sender)
        let idle = MacName(rawValue: "macbook-b")!
        try await put(mac(Self.laptop, seenMinutesAgo: 59), at: StatePath.mac(Self.laptop), in: store)
        try await put(mac(idle, seenMinutesAgo: 600), at: StatePath.mac(idle), in: store)
        let jobs = [
            job(1, kind: .implementTask, mac: Self.laptop, state: .paused), job(2, kind: .fixTask, mac: Self.laptop, state: .assigned)
        ]
        let epics = [epic(.running)]

        // 閉じてから 1 時間までは知らせない。ジョブを持っていない Mac は、長く戻らなくても知らせない
        #expect(try await notifier.notify(epics: epics, jobs: jobs, trusted: [deviceID]).isEmpty)
        clock.advance(minutes: 2)
        let notices = try await notifier.notify(epics: epics, jobs: jobs, trusted: [deviceID])
        let seenAt = Timestamp(Self.now.addingTimeInterval(-59 * 60))
        #expect(notices.map(\.keys) == [["mac/\(Self.laptop)/\(seenAt)"]])
        #expect(notices.first?.title == "macbook がオフライン")
        #expect(notices.first?.body == "ジョブ 2 件を持ったまま、1 時間以上戻っていません")
        #expect(notices.first?.target == ["mac": Self.laptop.rawValue])

        // 戻ってからまた止まったら、別の出来事として知らせ直す
        clock.advance(minutes: 30)
        try await put(mac(Self.laptop, seenMinutesAgo: 61), at: StatePath.mac(Self.laptop), in: store)
        #expect(try await notifier.notify(epics: epics, jobs: jobs, trusted: [deviceID]).count == 1)
        // ジョブが終われば、止まったままでも知らせない
        clock.advance(minutes: 10)
        try await put(mac(Self.laptop, seenMinutesAgo: 70), at: StatePath.mac(Self.laptop), in: store)
        #expect(try await notifier.notify(epics: epics, jobs: [job(1, mac: Self.laptop, state: .succeeded)], trusted: [deviceID]).isEmpty)
    }

    // MARK: - 宛先・送り直し

    @Test func waitsWithoutTrustedDevicesAndDoesNotRecord() async throws {
        let store = try await storeWithDevice()
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()
        let notifier = notifier(store, sender: sender)

        // 取り消した（確かめた一覧に無い）端末の宛先には送らず、記録も書かない（宛先ができたら知らせる）
        #expect(try await notifier.notify(epics: [epic(.asking)], jobs: [], trusted: []).isEmpty)
        #expect(await sender.sent.isEmpty)
        #expect(await store.data(at: StatePath.notifications) == nil)
        #expect(try await notifier.notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID]).count == 1)
    }

    @Test func ignoresDeviceFileNamedForAnotherDevice() async throws {
        let store = try await storeWithDevice()
        let other = IntentSignature.keyID(publicKeyDER: P256.Signing.PrivateKey().publicKey.derRepresentation)
        // ほかの端末のパスに置かれた宛先は使わない
        await store.put(StatePath.device(other), data: try #require(await store.data(at: StatePath.device(deviceID))))
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()

        #expect(try await notifier(store, sender: sender).notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID, other]).count == 1)
        #expect(await sender.sent.map(\.device) == [deviceID])
    }

    @Test func retriesAfterWaitWhenNoDeviceReceived() async throws {
        let store = try await storeWithDevice()
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()
        await sender.answer(.failed("503 ServiceUnavailable"), for: deviceID)
        let notifier = notifier(store, sender: sender)
        let epics = [epic(.asking)]

        // 届かなかったら記録から外し、待ってから送り直す
        #expect(try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID]).isEmpty)
        #expect(try await ledger(store).isEmpty)
        clock.advance(minutes: 0.5)
        #expect(try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID]).isEmpty)
        #expect(await sender.sent.count == 1)
        clock.advance(minutes: 1)
        await sender.answer(.delivered, for: deviceID)
        #expect(try await notifier.notify(epics: epics, jobs: [], trusted: [deviceID]).count == 1)
        #expect(await sender.sent.count == 2)
        #expect(try await ledger(store).count == 1)
    }

    @Test func keepsRecordWhenOnlyDeviceRejected() async throws {
        let store = try await storeWithDevice()
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()
        await sender.answer(.rejected("410 Unregistered"), for: deviceID)
        let notifier = notifier(store, sender: sender)

        // 宛先が使えないだけなら、送り直しても届かないので記録に残す
        #expect(try await notifier.notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID]).count == 1)
        #expect(try await ledger(store).count == 1)
        #expect(try await notifier.notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID]).isEmpty)
        #expect(await sender.sent.count == 1)
    }

    // MARK: - 記録

    @Test func prunesOnlyOldRecordsOfEventsThatEnded() async throws {
        let store = try await storeWithDevice()
        let questions = QuestionsFile(questions: [Self.question("q1", .open), Self.question("q2", .open)])
        try await put(questions, at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let base = "question/\(Self.repo)/\(Self.epicID)"
        let old = Timestamp(Self.now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recent = Timestamp(Self.now.addingTimeInterval(-24 * 60 * 60))
        let ledger = NotificationsFile(sent: [
            .init(key: "\(base)/q1/1/0", at: old), .init(key: "\(base)/gone/1/0", at: old), .init(key: "\(base)/ended/1/0", at: recent)
        ])
        try await put(ledger, at: StatePath.notifications, in: store)
        let sender = RecordingPushSender()

        let notices = try await notifier(store, sender: sender).notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID])
        #expect(notices.map(\.keys) == [["\(base)/q2/1/0"]])
        // 続いている出来事の記録は古くても残す。終わった出来事も、残す期間（7 日）の間は残す
        #expect(try await self.ledger(store) == ["\(base)/q1/1/0", "\(base)/ended/1/0", "\(base)/q2/1/0"])
    }

    @Test func doesNotSendWhenRecordIsUnreadable() async throws {
        let store = try await storeWithDevice()
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let future = Data(#"{"v":2,"sent":[]}"#.utf8)
        await store.put(StatePath.notifications, data: future)
        let sender = RecordingPushSender()

        // 何を知らせたか分からない記録は上書きせず、送らない
        #expect(try await notifier(store, sender: sender).notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID]).isEmpty)
        #expect(await sender.sent.isEmpty)
        #expect(await store.data(at: StatePath.notifications) == future)
    }

    @Test func doesNotSendWhenRecordCannotBeWritten() async throws {
        let store = try await storeWithDevice()
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        await store.failNextWrites(with: [.budgetExhausted(retryAfter: .seconds(30))])
        let sender = RecordingPushSender()

        // 記録を書けなければ送らない（送った後に書けず、次の周に二重に送ることがないよう、先に書く）
        await #expect(throws: CommanderError.self) {
            try await notifier(store, sender: sender).notify(epics: [epic(.asking)], jobs: [], trusted: [deviceID])
        }
        #expect(await sender.sent.isEmpty)
    }

    // MARK: - 常駐のループ

    /// 通知を送る常駐のループ。`rateLimit` は GitHub の REST の上限の残りを読むもの
    func loop(
        _ store: InMemoryStateStore,
        sender: RecordingPushSender,
        rateLimit: @escaping @Sendable () async -> GitHubRateLimit? = { nil }
    ) -> CommanderLoop {
        let clock = clock
        let context = CommanderContext(store: store, mac: EpicHandlersTests.commander) { clock.now }
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let publicKeys = [deviceID: device.publicKey.derRepresentation]
        return CommanderLoop(
            context: context,
            settings: .init(capacity: .init(claude: 1, build: 0), commanderVersion: "0.1.0"),
            verifier: { IntentVerifier(publicKeys: publicKeys) },
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: ScriptedRunner([])),
            workspace: FixedWorkspace(directory: FileManager.default.temporaryDirectory),
            status: { CommanderLoop.MachineStatus(diskFreeGB: 100, load: 0.5, selfCheck: selfCheck) },
            rateLimit: rateLimit,
            notifier: Notifier(context: context, sender: sender, log: { _ in }),
            log: { _ in }
        )
    }

    @Test func loopNotifiesAfterSweepingJobs() async throws {
        let store = try await storeWithDevice()
        try await put(epic(.asking), at: StatePath.epic(Self.repo, Self.epicID), in: store)
        try await put(QuestionsFile(questions: [Self.question("q1", .open)]), at: StatePath.questions(Self.repo, Self.epicID), in: store)
        let sender = RecordingPushSender()
        let loop = loop(store, sender: sender)

        try await loop.cycle()
        #expect(await sender.sent.map(\.notice.body) == ["質問 1 件が回答を待っています"])
        try await loop.cycle()
        #expect(await sender.sent.count == 1)
    }
}

// MARK: - GitHub の上限

extension NotifierTests {
    @Test func notifiesLowRateLimitOncePerWindow() async throws {
        let store = try await storeWithDevice()
        let sender = RecordingPushSender()
        let clock = clock
        let context = CommanderContext(store: store, mac: EpicHandlersTests.commander) { clock.now }
        let settings = Notifier.Settings(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let notifier = Notifier(context: context, sender: sender, settings: settings, log: { _ in })
        let resetAt = Timestamp(Self.now.addingTimeInterval(54 * 60))
        let low = GitHubRateLimit(limit: 5_000, remaining: 820, resetAt: resetAt)

        // 1,000 回までは知らせない
        let enough = GitHubRateLimit(limit: 5_000, remaining: 1_000, resetAt: resetAt)
        #expect(try await notifier.notify(epics: [], jobs: [], trusted: [deviceID], rateLimit: enough).isEmpty)
        let notices = try await notifier.notify(epics: [], jobs: [], trusted: [deviceID], rateLimit: low)
        #expect(notices.map(\.keys) == [["github/rate-limit/\(resetAt)"]])
        #expect(notices.first?.title == "GitHub の残りが少なくなりました")
        #expect(notices.first?.body == "残り 820 回（1 時間 5,000 回）。11:54 に戻ります。\naskhub status のループなど、GitHub を多く使うものを止めてください")
        // 通知から司令塔の Mac を開く
        #expect(notices.first?.target == ["mac": EpicHandlersTests.commander.rawValue])

        // 同じ窓では、もっと減っても知らせ直さない
        clock.advance(minutes: 5)
        let fewer = GitHubRateLimit(limit: 5_000, remaining: 100, resetAt: resetAt)
        #expect(try await notifier.notify(epics: [], jobs: [], trusted: [deviceID], rateLimit: fewer).isEmpty)
        // 戻る時刻を過ぎた残りでは知らせない。次の窓でまた少なくなれば知らせ直す
        clock.advance(minutes: 60)
        #expect(try await notifier.notify(epics: [], jobs: [], trusted: [deviceID], rateLimit: low).isEmpty)
        let next = GitHubRateLimit(limit: 5_000, remaining: 900, resetAt: Timestamp(clock.now.addingTimeInterval(30 * 60)))
        #expect(try await notifier.notify(epics: [], jobs: [], trusted: [deviceID], rateLimit: next).count == 1)
        #expect(await sender.sent.count == 2)
    }

    @Test func loopNotifiesLowRateLimitItRead() async throws {
        let store = try await storeWithDevice()
        let sender = RecordingPushSender()
        let resetAt = Timestamp(Self.now.addingTimeInterval(30 * 60))
        let loop = loop(store, sender: sender) { GitHubRateLimit(limit: 5_000, remaining: 820, resetAt: resetAt) }

        // 周の初めに読んだ残りで知らせる。同じ窓では、次の周で知らせ直さない
        try await loop.cycle()
        #expect(await sender.sent.map(\.notice.title) == ["GitHub の残りが少なくなりました"])
        clock.advance(minutes: 2)
        try await loop.cycle()
        #expect(await sender.sent.count == 1)
    }
}
