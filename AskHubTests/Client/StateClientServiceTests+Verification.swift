@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 実機確認: マージした epic のゴールの完了の条件を v1 から並べ、「確認した」は答えだけ、「問題あり」は答えと依頼を一緒に送る
extension StateClientServiceTests {
    private static let verificationBase = "repos/\(repo)/epics/\(epicID)"

    /// 最終 PR #512 をマージした epic（完了の条件が 2 つ）
    static func mergedEpic(stage: String = "merged", extra: [String: String] = [:]) -> [String: String] {
        askingEpic(extra: [
            "\(verificationBase)/epic.json": """
            {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
             "mac":"mac-mini","branch":"askhub/\(epicID)","finalPullRequest":512,"goalVersion":1,"origin":null,
             "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T07:40:00Z"}
            """,
            "\(verificationBase)/goal.json": """
            {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],
             "doneWhen":["毎日入れ替わる","ダークモードで読める"],
             "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"done"}],"humanTasks":[]}
            """
        ].merging(extra) { _, new in new })
    }

    @Test
    func mergedEpicShowsVerificationsAndSendsConfirmation() async throws {
        let fixture = try makeService(files: Self.mergedEpic())
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let items = try #require(snapshot.epic(Self.epicID)?.finalReview?.verifications)
        #expect(items.map(\.id) == ["v1", "v2"])
        #expect(items.map(\.text) == ["毎日入れ替わる", "ダークモードで読める"])
        #expect(items.allSatisfy { $0.state == .ready(build: nil) })
        let confirm = HumanIntent.verify(epicID: Self.epicID, itemID: "v1", reply: .confirmed)
        #expect(service.supports(confirm))

        try await service.perform(confirm)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let verify = try VerifyIntent(envelope: envelope)
        #expect(verify.target.item == "v1")
        #expect(verify.target.goalVersion == 1)
        #expect(verify.result == .confirmed)
        // 司令塔が受け取る前から、答えた結果として出し、答え直しは送らない
        let shown = try await service.fetchSnapshot().epic(Self.epicID)?.finalReview?.verifications
        #expect(shown?.map(\.state) == [.confirmed, .ready(build: nil)])
        #expect(!service.supports(confirm))
    }

    @Test
    func problemSendsAnswerAndRequest() async throws {
        let fixture = try makeService(files: Self.mergedEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let receipt = try await service.perform(.verify(epicID: Self.epicID, itemID: "v2", reply: .problem(note: " 線が背景に溶ける ")))

        let envelopes = try await sentEnvelopes(in: fixture)
        #expect(envelopes.map(\.kind) == [VerifyIntent.kind, RequestIntent.kind])
        let verify = try VerifyIntent(envelope: envelopes[0])
        #expect(verify.result == .problem)
        #expect(verify.note == "線が背景に溶ける")
        let request = try RequestIntent(envelope: envelopes[1])
        #expect(request.repo.rawValue == Self.repo)
        #expect(request.title == "実機確認で問題: ダークモードで読める")
        #expect(request.body.contains("epic「ランキング」（最終 PR #512）の実機確認で、問題がありました。"))
        #expect(request.body.contains("確かめたこと（v2）: ダークモードで読める"))
        #expect(request.body.hasSuffix("線が背景に溶ける"))
        // 依頼は、司令塔が受け取る前から新しい epic として出す
        let requested = try #require(receipt.requestedEpicID)
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.epic(requested)?.stage == .request)
        #expect(snapshot.epic(Self.epicID)?.finalReview?.verifications.last?.state == .problem(note: "線が背景に溶ける"))
    }

    @Test
    func emptyProblemIsNotSent() async throws {
        let fixture = try makeService(files: Self.mergedEpic())
        _ = try await fixture.service.fetchSnapshot()
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.verify(epicID: Self.epicID, itemID: "v1", reply: .problem(note: "  ")))
        }
        #expect(try await sentEnvelopes(in: fixture).isEmpty)
    }

    /// 司令塔が記録した答えを出し、その項目には送らない。マージする前の epic には実機確認を出さない
    @Test
    func recordedAnswersAndUnmergedEpics() async throws {
        let answers = """
        {"v":1,"answers":[{"id":"v2","result":"problem","note":"線が見えない",
          "intent":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"},"at":"2027-01-15T07:50:00Z"}]}
        """
        let service = try makeService(files: Self.mergedEpic(extra: ["\(Self.verificationBase)/verifications.json": answers])).service
        let items = try await service.fetchSnapshot().epic(Self.epicID)?.finalReview?.verifications
        #expect(items?.map(\.state) == [.ready(build: nil), .problem(note: "線が見えない")])
        #expect(!service.supports(.verify(epicID: Self.epicID, itemID: "v2", reply: .confirmed)))
        #expect(service.supports(.verify(epicID: Self.epicID, itemID: "v1", reply: .confirmed)))

        let reviewing = try makeService(files: Self.mergedEpic(stage: "reviewing")).service
        #expect(try await reviewing.fetchSnapshot().epic(Self.epicID)?.finalReview?.verifications.isEmpty == true)
        #expect(!reviewing.supports(.verify(epicID: Self.epicID, itemID: "v1", reply: .confirmed)))
    }

    /// 「問題あり」の答えだけが届いて依頼を送れなかったときは、同じ説明で送り直すと依頼だけを送る（答えは重ねない）
    @Test
    func problemRetrySendsOnlyTheMissingRequest() async throws {
        let fixture = try makeService(files: Self.mergedEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        // 答えだけを送った形（依頼の送信は失敗した）
        let repo = try #require(RepositoryFullName(rawValue: Self.repo))
        let target = VerificationTarget(repo: repo, epic: try #require(ULID(rawValue: Self.epicID)), item: "v2", goalVersion: 1)
        let now = now
        try await IntentSender(store: fixture.store, key: fixture.key) { now }.send(.verify(target, result: .problem, note: "線が見えない"))
        _ = try await service.fetchSnapshot()
        // 違う説明・「確認した」は送らない
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.verify(epicID: Self.epicID, itemID: "v2", reply: .problem(note: "別の問題")))
        }
        try await service.perform(.verify(epicID: Self.epicID, itemID: "v2", reply: .problem(note: "線が見えない")))
        // 同じ時刻に送ると番号の順が決まらないので、種類ごとの数で確かめる
        let kinds = try await sentEnvelopes(in: fixture).map(\.kind)
        #expect(kinds.filter { $0 == VerifyIntent.kind }.count == 1, "\(kinds)")
        #expect(kinds.filter { $0 == RequestIntent.kind }.count == 1, "\(kinds)")
    }

    /// 司令塔が「問題あり」を記録した後に送り直すと、依頼だけを作る
    @Test
    func problemRetryAfterRecordSendsRequest() async throws {
        let answers = """
        {"v":1,"answers":[{"id":"v1","result":"problem","note":"先週の分が出る",
          "intent":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"},"at":"2027-01-15T07:50:00Z"}]}
        """
        let fixture = try makeService(files: Self.mergedEpic(extra: ["\(Self.verificationBase)/verifications.json": answers]))
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.verify(epicID: Self.epicID, itemID: "v1", reply: .problem(note: "先週の分が出る")))
        let sent = try await sentEnvelopes(in: fixture)
        #expect(sent.map(\.kind) == [RequestIntent.kind])
        #expect(try RequestIntent(envelope: sent[0]).body.hasSuffix("先週の分が出る"))
    }

    /// 答えの記録を読めなければ、どの項目に答えたかが分からないので、実機確認を出さず答えも送らない
    @Test
    func unreadableAnswersHideVerifications() async throws {
        let files = Self.mergedEpic(extra: ["\(Self.verificationBase)/verifications.json": #"{"v":99,"answers":[]}"#])
        let service = try makeService(files: files).service
        let snapshot = try await service.fetchSnapshot()
        #expect(!snapshot.sourceFailures.isEmpty)
        #expect(snapshot.epic(Self.epicID)?.finalReview?.verifications.isEmpty == true)
        #expect(!service.supports(.verify(epicID: Self.epicID, itemID: "v1", reply: .confirmed)))
    }
}
