@testable import AskHub
import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 最終 PR への意図を送る前の確かめ: 人が見た head とカードに結びつける・本文の上限・まとめて送る途中の失敗の後の送り直し
extension StateClientServiceTests {
    /// 指示と判断の本文の上限は、司令塔と同じく Unicode のコードポイントで数える（結合文字を含む文は、見た目の文字数より多い）
    @Test
    func textLimitsCountUnicodeScalars() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        // 濁点を結合文字で書いた「が」は、見た目は 1 文字でコードポイントは 2 つ
        let combined = "か\u{3099}"
        let tooLong = String(repeating: combined, count: 5_001)
        #expect(tooLong.count == 5_001 && tooLong.unicodeScalars.count == 10_002)
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.instructFinal(epicID: Self.epicID, headCommit: Self.finalHead, instruction: tooLong))
        }
        await #expect(throws: ClientServiceError.self) {
            let reply = DecisionReply.fix(tooLong)
            try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: reply))
        }
        let nothing = try await sentEnvelopes(in: fixture)
        #expect(nothing.isEmpty)

        // ちょうど上限（10,000 コードポイント）なら送る
        let atLimit = String(repeating: combined, count: 5_000)
        try await service.perform(.instructFinal(epicID: Self.epicID, headCommit: Self.finalHead, instruction: atLimit))
        let sent = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(sent.string("instruction")?.unicodeScalars.count == 10_000)
    }

    /// カードを見た後に head が進んだら（直しが push された）、見ていない head に答えを結びつけないよう、送らずに断る
    @Test
    func answerForAdvancedHeadIsNotSent() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let input = Self.pullRequestInput(head: Self.finalNewHead)
        let review = Self.finalJob(
            Self.secondReviewID,
            kind: "reviewFinalPullRequest",
            dependsOn: [Self.reviewID],
            input: input,
            at: "07:50"
        )
        await put(review, in: fixture.store)
        await put(Self.finalAttempt(Self.secondReviewID, outputs: #"{"verdict":"ready","mergeRisks":[]}"#), in: fixture.store)
        _ = try await service.fetchSnapshot()

        let stale = HumanIntent.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: .accept)
        await #expect(throws: ClientServiceError(message: "最終 PR が更新されました。見直してから答えてください")) {
            try await service.perform(stale)
        }
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.finalHead, decisionIDs: ["d1", "d4"]))
        }
        let nothing = try await sentEnvelopes(in: fixture)
        #expect(nothing.isEmpty)

        // 見直した（今の head で答えた）ものは送る
        try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalNewHead, reply: .accept))
        let sent = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(sent.targetVersion == Self.finalNewHead)
    }

    /// まとめて OK は、画面に出していなかった答え待ちのカード（見た後に足された）があれば、どれも送らない
    @Test
    func acceptAllDoesNotIncludeUnseenCards() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        await #expect(throws: ClientServiceError(message: "最終 PR が更新されました。見直してから答えてください")) {
            try await service.perform(.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.finalHead, decisionIDs: ["d1"]))
        }
        let nothing = try await sentEnvelopes(in: fixture)
        #expect(nothing.isEmpty)
    }

    /// まとめて OK の途中で書き込みが失敗したら、読み直す前に送り直しても、送れた答えは送り直さず残りだけを送る
    /// （同じカードへの答え直しは司令塔が断る）
    @Test
    func acceptAllResendAfterPartialFailureSendsOnlyTheRest() async throws {
        let base = InMemoryStateStore(files: Self.reviewingEpic().mapValues { Data($0.utf8) })
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let now = now
        let service = StateClientService(store: FailingWriteStore(base: base, failingWrite: 2), key: key) { now }
        _ = try await service.fetchSnapshot()
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.finalHead, decisionIDs: ["d1", "d4"])
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(acceptAll)
        }
        try await service.perform(acceptAll)
        let sent = try await sentEnvelopes(in: Fixture(service: service, store: base, key: key))
        #expect(sent.compactMap { $0.target?.id }.sorted() == ["d1", "d4"])
    }
}

/// 決まった回目の書き込みだけ失敗させる（まとめて送る途中の失敗を再現する）
private actor FailingWriteStore: StateStore {
    let base: InMemoryStateStore
    let failingWrite: Int
    private var writes = 0

    init(base: InMemoryStateStore, failingWrite: Int) {
        self.base = base
        self.failingWrite = failingWrite
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await base.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        writes += 1
        if writes == failingWrite {
            throw .serverError(status: 502)
        }
        return try await base.write(path, data: data, replacing: sha, message: message)
    }
}
