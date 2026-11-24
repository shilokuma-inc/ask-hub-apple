@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 実機確認をまとめて答える（`closeVerifications`）: マージした epic の、まだ答えていない項目すべてに同じ答えを 1 回で記録する
struct CloseVerificationsHandlerTests {
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
            handlers: ["verify": VerifyHandler(), "closeVerifications": CloseVerificationsHandler()]
        )
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func saved() async throws -> VerificationsFile? {
        try await store.data(at: path).map { try StateFileCoder.decode(VerificationsFile.self, from: $0) }
    }

    /// 完了の条件が 3 つのゴール（v1〜v3）と、その段階の epic を置く
    private func prepare(_ stage: EpicStage = .merged, goalVersion: Int = 2) async throws {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID, repo: Self.repo, title: "振り返り", stage: stage, goalVersion: goalVersion, createdAt: time, updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let goal = GoalFile(
            version: goalVersion,
            summary: "週の振り返り",
            doneWhen: ["日曜の夜に開ける", "ダークモードで読める", "週をまたいでも残る"],
            tasks: [.init(id: "t1", title: "画面")]
        )
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
    }

    private func store(_ envelope: IntentEnvelope) async throws {
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: envelope.nonce), data: CanonicalJSON.data(for: stored))
    }

    private func envelope(_ result: CloseVerificationsIntent.Result, note: String, version: Int, nonce: ULID) -> IntentEnvelope {
        let target = EpicTarget(repo: Self.repo, epic: Self.epicID, version: version)
        let reference = IntentReference(keyId: keyID, nonce: nonce)
        let close = CloseVerificationsIntent(target: target, result: result, note: note, intent: reference)
        return IntentEnvelope(
            kind: CloseVerificationsIntent.kind,
            repo: Self.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: close.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
    }

    /// 署名した `closeVerifications` を置く
    @discardableResult
    private func close(
        _ result: CloseVerificationsIntent.Result,
        note: String = "",
        version: Int = 2,
        second: TimeInterval = 0
    ) async throws -> IntentReference {
        let nonce = ULID.generate(at: Self.now.addingTimeInterval(second))
        try await store(envelope(result, note: note, version: version, nonce: nonce))
        return IntentReference(keyId: keyID, nonce: nonce)
    }

    /// 署名した `verify` を置く
    private func verify(_ item: String, second: TimeInterval) async throws -> IntentReference {
        let nonce = ULID.generate(at: Self.now.addingTimeInterval(second))
        let target = VerificationTarget(repo: Self.repo, epic: Self.epicID, item: item, goalVersion: 2)
        let verify = VerifyIntent(target: target, result: .confirmed, intent: IntentReference(keyId: keyID, nonce: nonce))
        try await store(IntentEnvelope(
            kind: VerifyIntent.kind,
            repo: Self.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: verify.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        ))
        return verify.intent
    }

    /// 1 つ答えた後にまとめて閉じると、残りの 2 つだけを、閉じた理由と一緒に項目の順に足す
    @Test func closesOnlyUnansweredItemsInOrder() async throws {
        try await prepare()
        let first = try await verify("v2", second: 0)
        let closing = try await close(.skipped, note: "次の版を配信した", second: 1)
        #expect(try await intake.processPending() == [.accepted(kind: "verify"), .accepted(kind: "closeVerifications")])
        let time = Timestamp(Self.now)
        #expect(try await saved()?.answers == [
            .init(id: "v2", result: .confirmed, intent: first, at: time),
            .init(id: "v1", result: .skipped, note: "次の版を配信した", intent: closing, at: time),
            .init(id: "v3", result: .skipped, note: "次の版を配信した", intent: closing, at: time)
        ])
    }

    /// まとめて確認したは、ファイルが無ければ作り、すべての項目を確認したにする。閉じた後の 1 項目への答えは断る
    @Test func confirmsAllAndRefusesLaterAnswers() async throws {
        try await prepare()
        let closing = try await close(.confirmed)
        _ = try await verify("v1", second: 1)
        #expect(try await intake.processPending() == [
            .accepted(kind: "closeVerifications"),
            .rejected(kind: "verify", reason: "実機確認の項目 v1 にはもう答えている")
        ])
        #expect(try await saved()?.answers.map(\.id) == ["v1", "v2", "v3"])
        #expect(try await saved()?.answers.allSatisfy { $0.result == .confirmed && $0.intent == closing } == true)
    }

    /// 答えていない項目が無ければ、何も書かずに受け付ける
    @Test func acceptsWhenNothingRemains() async throws {
        try await prepare()
        try await close(.confirmed)
        try await close(.skipped, second: 1)
        #expect(try await intake.processPending() == [.accepted(kind: "closeVerifications"), .accepted(kind: "closeVerifications")])
        #expect(try await saved()?.answers.allSatisfy { $0.result == .confirmed } == true)
    }

    @Test func rejectsBeforeMergeAndOtherGoalVersions() async throws {
        try await prepare(.reviewing)
        try await close(.confirmed)
        #expect(try await intake.processPending() == [
            .rejected(kind: "closeVerifications", reason: "最終 PR をマージした epic でない（今は reviewing）")
        ])
        try await prepare()
        try await close(.confirmed, version: 1, second: 1)
        #expect(try await intake.processPending() == [.rejected(kind: "closeVerifications", reason: "ゴールの版が違う（今の版は 2）")])
        #expect(try await saved() == nil)
    }

    /// 記録した後に止まって、同じ意図をもう一度処理しても、受け付けた結果は変わらない
    @Test func retryingSameIntentIsAccepted() async throws {
        try await prepare()
        let envelope = envelope(.skipped, note: "", version: 2, nonce: ULID.generate(at: Self.now))
        #expect(try await CloseVerificationsHandler().handle(envelope, in: context) == .accept)
        #expect(try await CloseVerificationsHandler().handle(envelope, in: context) == .accept)
        #expect(try await saved()?.answers.count == 3)
    }
}
