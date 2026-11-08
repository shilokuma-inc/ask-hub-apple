@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人がする作業を終えた意図（`humanTaskDone`）の受け付けと、ロックを外す・最終 PR の段取りを待つ
struct HumanTaskFlowTests {
    static let repo = EpicHandlersTests.repo
    static let laptop = EpicHandlersTests.laptop
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let origin = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
    )
    /// 渡すファイルの中身
    static let plist = Data("<plist><dict><key>PROJECT_ID</key><string>askhub-sandbox</string></dict></plist>".utf8)

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var context: CommanderContext { CommanderContext(store: store, mac: EpicHandlersTests.commander) { Self.now } }

    private var intake: IntentIntake {
        IntentIntake(
            context: context,
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["humanTaskDone": HumanTaskDoneHandler()]
        )
    }

    /// t1（前提なし）・t2（t1 と h1 が前提）・t3（h1 と h2 が前提）。h1 は「終わった」、h2 はファイルを渡す、h3 は Secrets に入れる
    static func goal(version: Int = 1) -> GoalFile {
        GoalFile(
            version: version,
            summary: "広告を出す",
            doneWhen: ["広告が出る"],
            tasks: [
                .init(id: "t1", title: "広告の枠を作る"),
                .init(id: "t2", title: "広告の SDK を入れる", dependsOn: ["t1", "h1"], state: .locked),
                .init(id: "t3", title: "広告を出し分ける", dependsOn: ["h1", "h2"], state: .locked)
            ],
            humanTasks: [
                .init(id: "h1", title: "AdMob のアカウントを作る", why: "広告の SDK が使う", steps: ["AdMob に登録する"]),
                .init(
                    id: "h2",
                    title: "Firebase のプロジェクトを作る",
                    why: "広告の SDK が設定ファイルを読む",
                    steps: ["GoogleService-Info.plist を落とす"],
                    handover: .init(kind: .file)
                ),
                .init(
                    id: "h3",
                    title: "配信の鍵を Secrets に入れる",
                    why: "CI が配信する",
                    steps: ["GitHub の設定画面で入れる"],
                    handover: .init(kind: .secret, name: "ADS_KEY")
                )
            ]
        )
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func read<File: StateFile>(_ type: File.Type, at path: String) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    private func savedGoal() async throws -> GoalFile {
        try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, Self.epicID)))
    }

    private func epic(_ stage: EpicStage = .running) -> EpicFile {
        let time = Timestamp(Self.now)
        return EpicFile(
            id: Self.epicID, repo: Self.repo, title: "広告", stage: stage, mac: Self.laptop, goalVersion: 1, createdAt: time, updatedAt: time
        )
    }

    private func prepare(_ stage: EpicStage = .running, goal: GoalFile = HumanTaskFlowTests.goal()) async throws {
        try await put(epic(stage), at: StatePath.epic(Self.repo, Self.epicID))
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
    }

    /// 渡すファイルの参照（添付と同じ形）
    static func attachment(of data: Data = plist, name: String = "GoogleService-Info.plist") -> RequestAttachment {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RequestAttachment(number: 1, name: name, size: data.count, sha256: digest)
    }

    /// 署名した `humanTaskDone` を置く。`content` があれば、ファイルの中身を意図より先に置く
    @discardableResult
    private func send(
        _ task: String,
        version: Int = 1,
        file: RequestAttachment? = nil,
        content: Data? = nil,
        second: TimeInterval = 0
    ) async throws -> IntentReference {
        let nonce = ULID.generate(at: Self.now.addingTimeInterval(second))
        if let content { await store.put(StatePath.attachment(device: keyID, nonce: nonce, number: 1), data: content) }
        let target = HumanTaskTarget(repo: Self.repo, epic: Self.epicID, task: task, goalVersion: version)
        let done = HumanTaskDoneIntent(target: target, file: file, intent: IntentReference(keyId: keyID, nonce: nonce))
        let envelope = IntentEnvelope(
            kind: HumanTaskDoneIntent.kind,
            repo: Self.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: done.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return done.intent
    }

    // MARK: - 受け付け

    /// 「終わった」で作業を done にし、人がする作業の依存がすべて済んだタスクのロックを外す（ほかのタスクへの依存が残っていても）
    @Test func doneUnlocksTasksWhoseHumanTasksAreDone() async throws {
        try await prepare()
        let intent = try await send("h1")
        #expect(try await intake.processPending() == [.accepted(kind: "humanTaskDone")])
        let goal = try await savedGoal()
        #expect(goal.humanTasks[0].state == .done)
        #expect(goal.humanTasks[0].done == GoalFile.Completion(intent: intent, at: Timestamp(Self.now)))
        // t2 は t1 がまだ済んでいないが、人がする作業の待ちではなくなる。t3 は h2 を待つ
        #expect(goal.tasks.map(\.state) == [.pending, .pending, .locked])
        // 人が読むゴールの中身は変えないので、版は上げない
        #expect(goal.version == 1)
    }

    /// ファイルを渡す作業は、置いた中身の大きさとハッシュが封筒と合えば受け付け、どのファイルで終えたかを書く
    @Test func fileTaskRecordsTheFile() async throws {
        var goal = Self.goal()
        goal.humanTasks[0].state = .done
        goal.humanTasks[0].done = .init(intent: Self.origin, at: Timestamp(Self.now))
        try await prepare(goal: goal)
        let intent = try await send("h2", file: Self.attachment(), content: Self.plist)
        #expect(try await intake.processPending() == [.accepted(kind: "humanTaskDone")])
        let saved = try await savedGoal()
        #expect(saved.humanTasks[1].done == GoalFile.Completion(intent: intent, at: Timestamp(Self.now), file: Self.attachment()))
        #expect(saved.tasks.map(\.state) == [.pending, .pending, .pending])
    }

    /// Secrets に入れる作業は、人が GitHub の設定画面で入れてから「終わった」を押す（値は受け取らない）
    @Test func secretTaskIsDoneWithoutValue() async throws {
        try await prepare()
        try await send("h3")
        #expect(try await intake.processPending() == [.accepted(kind: "humanTaskDone")])
        #expect(try await savedGoal().humanTasks[2].state == .done)
    }

    /// 開始の前（ゴールの確認の間）に終えてもよい
    @Test func acceptsBeforeStart() async throws {
        try await prepare(.awaitingStart)
        try await send("h1")
        #expect(try await intake.processPending() == [.accepted(kind: "humanTaskDone")])
        #expect(try await savedGoal().tasks.map(\.state) == [.pending, .pending, .locked])
    }

    /// 終えたことを書いた後、処理した記録を書く前に止まっても、やり直すと受け付ける（2 度書かない）
    @Test func retryAfterWritingAccepts() async throws {
        try await prepare()
        let intent = try await send("h1")
        let stored = try JSONValue(parsing: #require(await store.data(at: StatePath.intent(device: keyID, nonce: intent.nonce))))
        let envelope = try intake.verifier.verify(stored: stored, now: Self.now)
        #expect(try await HumanTaskDoneHandler().handle(envelope, in: context) == .accept)
        let written = try await savedGoal()
        #expect(try await HumanTaskDoneHandler().handle(envelope, in: context) == .accept)
        #expect(try await savedGoal() == written)
    }

    // MARK: - 断り

    @Test func rejectsStaleGoalVersion() async throws {
        try await prepare(goal: Self.goal(version: 2))
        try await send("h1", version: 1)
        let outcome = try await intake.processPending()
        #expect(outcome == [.rejected(kind: "humanTaskDone", reason: "ゴールが直された（今の版は 2）。新しいゴールを見てから送り直す")])
        #expect(try await savedGoal().humanTasks[0].state == .pending)
    }

    /// ファイルを渡す作業にファイルが無い・渡さない作業にファイルがある
    @Test func rejectsHandoverKindMismatch() async throws {
        try await prepare()
        try await send("h2")
        try await send("h1", file: Self.attachment(), content: Self.plist, second: 1)
        try await send("h3", file: Self.attachment(), content: Self.plist, second: 2)
        let outcome = try await intake.processPending()
        #expect(outcome == [
            .rejected(kind: "humanTaskDone", reason: "人がする作業 h2 はファイルを渡す作業なのに、ファイルが無い"),
            .rejected(kind: "humanTaskDone", reason: "人がする作業 h1 はファイルを渡さない作業なのに、ファイルがある"),
            .rejected(kind: "humanTaskDone", reason: "人がする作業 h3 はファイルを渡さない作業なのに、ファイルがある")
        ])
        #expect(try await savedGoal().humanTasks.map(\.state) == [.pending, .pending, .pending])
    }

    /// 置いた中身が封筒と合わない・無いときは、記録を作らずに残す（置き直せば次の周で受け付ける）
    @Test func ignoresFileThatDoesNotMatch() async throws {
        try await prepare()
        try await send("h2", file: Self.attachment(), content: Data("置き換えた".utf8))
        try await send("h2", file: Self.attachment(), second: 1)
        let outcome = try await intake.processPending()
        #expect(outcome == [
            .ignored(reason: "渡すファイル（GoogleService-Info.plist）の大きさかハッシュが、署名した意図と合わない"),
            .ignored(reason: "渡すファイル（GoogleService-Info.plist）が無い")
        ])
        #expect(try await savedGoal().humanTasks[1].state == .pending)
        #expect(try await intake.pending().count == 2)
    }

    /// 終えた作業をもう一度終える・無い作業・開始の前の確認が済んでいない epic
    @Test func rejectsDoneUnknownOrEarlyTasks() async throws {
        try await prepare()
        try await send("h1")
        try await send("h1", second: 1)
        try await send("h9", second: 2)
        var outcome = try await intake.processPending()
        #expect(outcome == [
            .accepted(kind: "humanTaskDone"),
            .rejected(kind: "humanTaskDone", reason: "人がする作業 h1 はもう終えている"),
            .rejected(kind: "humanTaskDone", reason: "人がする作業 h9 が無い")
        ])
        try await put(epic(.checking), at: StatePath.epic(Self.repo, Self.epicID))
        try await send("h3", second: 3)
        outcome = try await intake.processPending()
        #expect(outcome == [.rejected(kind: "humanTaskDone", reason: "人がする作業を終えられる段階でない（今は checking）")])
    }
}
