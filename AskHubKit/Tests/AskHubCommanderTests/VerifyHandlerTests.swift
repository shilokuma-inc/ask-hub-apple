@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 実機確認への答え（`verify`）: マージした epic の、ゴールの完了の条件の項目に 1 回だけ答え、`verifications.json` に記録する
struct VerifyHandlerTests {
    static let repo = EpicHandlersTests.repo
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var context: CommanderContext { CommanderContext(store: store, mac: EpicHandlersTests.commander) { Self.now } }
    var path: String { StatePath.verifications(Self.repo, Self.epicID) }

    private var intake: IntentIntake {
        IntentIntake(
            context: context,
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["verify": VerifyHandler()]
        )
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func saved() async throws -> VerificationsFile? {
        try await store.data(at: path).map { try StateFileCoder.decode(VerificationsFile.self, from: $0) }
    }

    /// 完了の条件が 2 つのゴール（v1・v2）と、その段階の epic を置く
    private func prepare(_ stage: EpicStage = .merged, goalVersion: Int = 2) async throws {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID, repo: Self.repo, title: "振り返り", stage: stage, goalVersion: goalVersion, createdAt: time, updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let goal = GoalFile(
            version: goalVersion,
            summary: "週の振り返り",
            doneWhen: ["日曜の夜に開ける", "ダークモードで読める"],
            tasks: [.init(id: "t1", title: "画面")]
        )
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
    }

    /// 署名した `verify` を置く
    @discardableResult
    private func send(
        _ item: String,
        result: VerifyIntent.Result,
        note: String = "",
        version: Int = 2,
        second: TimeInterval = 0
    ) async throws -> IntentReference {
        let nonce = ULID.generate(at: Self.now.addingTimeInterval(second))
        let target = VerificationTarget(repo: Self.repo, epic: Self.epicID, item: item, goalVersion: version)
        let verify = VerifyIntent(target: target, result: result, note: note, intent: IntentReference(keyId: keyID, nonce: nonce))
        let envelope = IntentEnvelope(
            kind: VerifyIntent.kind,
            repo: Self.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: verify.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return verify.intent
    }

    @Test func recordsConfirmedAndProblemInOrder() async throws {
        try await prepare()
        let confirmed = try await send("v2", result: .confirmed)
        let problem = try await send("v1", result: .problem, note: "先週の振り返りが出る", second: 1)
        #expect(try await intake.processPending() == [.accepted(kind: "verify"), .accepted(kind: "verify")])
        let file = try #require(try await saved())
        #expect(file.answers == [
            .init(id: "v2", result: .confirmed, intent: confirmed, at: Timestamp(Self.now)),
            .init(id: "v1", result: .problem, note: "先週の振り返りが出る", intent: problem, at: Timestamp(Self.now))
        ])
    }

    @Test func answersEachItemOnlyOnce() async throws {
        try await prepare()
        let first = try await send("v1", result: .confirmed)
        try await send("v1", result: .problem, note: "やっぱり出ない", second: 1)
        #expect(try await intake.processPending() == [
            .accepted(kind: "verify"),
            .rejected(kind: "verify", reason: "実機確認の項目 v1 にはもう答えている")
        ])
        #expect(try await saved()?.answers.map(\.intent) == [first])
    }

    @Test func rejectsBeforeMergeAndUnknownItems() async throws {
        try await prepare(.reviewing)
        try await send("v1", result: .confirmed)
        #expect(try await intake.processPending() == [.rejected(kind: "verify", reason: "最終 PR をマージした epic でない（今は reviewing）")])

        try await prepare()
        try await send("v3", result: .confirmed, second: 1)
        try await send("v1", result: .confirmed, version: 1, second: 2)
        #expect(try await intake.processPending() == [
            .rejected(kind: "verify", reason: "実機確認の項目 v3 が無い（完了の条件は 2 件）"),
            .rejected(kind: "verify", reason: "ゴールの版が違う（今の版は 2）")
        ])
        #expect(try await saved() == nil)
    }

    /// 記録した後に止まって、同じ意図をもう一度処理しても、受け付けた結果は変わらない
    @Test func retryingSameIntentIsAccepted() async throws {
        try await prepare()
        let intent = try await send("v2", result: .confirmed)
        let envelope = IntentEnvelope(
            kind: VerifyIntent.kind,
            repo: Self.repo,
            target: VerificationTarget(repo: Self.repo, epic: Self.epicID, item: "v2", goalVersion: 2).target,
            targetVersion: "2",
            payload: ["result": .string("confirmed")],
            issuedAt: Timestamp(Self.now),
            nonce: intent.nonce,
            keyId: intent.keyId
        )
        #expect(try await VerifyHandler().handle(envelope, in: context) == .accept)
        #expect(try await VerifyHandler().handle(envelope, in: context) == .accept)
        #expect(try await saved()?.answers.count == 1)
    }
}
