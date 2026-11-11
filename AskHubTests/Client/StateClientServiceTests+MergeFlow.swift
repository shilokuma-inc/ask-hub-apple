@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// マージの承認を送ってから、司令塔が受け付け、マージのジョブが動いて成功し、epic をマージ済みにするまでを、実際の順に読み直す
extension StateClientServiceTests {
    private static let flowMergeID = "01JCJ0F0000000000000000210"
    private static let flowCleanUpID = "01JCJ0F0000000000000000211"
    private static let mergeCommit = String(repeating: "e", count: 40)

    /// 見える仮決め（d1）に答え終え、人の承認を待っている epic の判断の一覧
    private static let answeredDecisions = """
    {"v":1,"items":[
      {"id":"d1","task":"t2","pullRequest":41,"visible":true,"what":"見出しを短くした","why":"iPhone の幅に収める","alternatives":[],
       "answer":{"choice":"ok","note":"","intent":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCJ0F0000000000000000298"},
                 "at":"2027-01-15T07:30:00Z"}},
      {"id":"d3","task":"t1","pullRequest":40,"visible":false,"what":"集計は UTC の日付で区切る","why":"サーバーと合わせる","alternatives":[]}
    ]}
    """

    /// 司令塔が書く epic.json。`merge` はマージの記録（マージする前は nil）
    private static func flowEpic(stage: String, merge: String? = nil, updatedAt: String) -> String {
        let record = merge.map { #""merge":\#($0),"# } ?? ""
        return """
        {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
         "mac":"mac-mini","branch":"askhub/\(epicID)","finalPullRequest":512,\(record)"goalVersion":1,"origin":null,
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T\(updatedAt):00Z"}
        """
    }

    private static func flowDate(_ time: String) -> Date {
        ISO8601DateFormatter().date(from: "2027-01-15T\(time):00Z") ?? .distantPast
    }

    /// 承認を送る → 司令塔が受け付ける（consumed が accepted）→ マージのジョブが running から succeeded になる →
    /// epic.json が merged になり、マージの記録が書かれる。読み直すたびの最終 PR の状態が、マージ中からマージ済みに進む
    @Test
    func approvedMergeTurnsMergedInOrder() async throws {
        let decisionsPath = "\(Self.finalBase)/decisions.json"
        let fixture = try makeService(files: Self.reviewingEpic(extra: [[decisionsPath: Self.answeredDecisions]]))
        let service = fixture.service
        let store = ClientStore(service: service, now: { [now] in now })
        func state() -> FinalReview.State? {
            store.epic(Self.epicID)?.finalReview?.state
        }

        await store.refresh()
        #expect(state() == .reviewable)
        #expect(store.epic(Self.epicID)?.finalReview?.canMerge == true)

        // 承認を送る: 司令塔が受け取るまでは、送った結果としてマージ中に出す
        #expect(await store.send(.merge(epicID: Self.epicID, headCommit: Self.finalHead)) != .alreadySent)
        let approval = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(approval.kind == ApproveMergeIntent.kind)
        #expect(state() == .merging)
        await store.refresh()
        #expect(state() == .merging)

        // 司令塔が受け付けた: 承認した head を固定したマージのジョブを作り、受け付けた記録を書く
        await put(Self.flowMerge(state: "assigned", attempts: 0), in: fixture.store)
        let consumed = #"{"v":1,"kind":"approveMerge","consumedAt":"2027-01-15T07:45:30Z","result":"accepted"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: approval.nonce), data: Data(consumed.utf8))
        await store.refresh()
        #expect(state() == .merging)

        // マージのジョブが動いている
        await put(Self.flowMerge(state: "running"), in: fixture.store)
        await put(Self.flowAttempt(outcome: "running", outputs: "null"), in: fixture.store)
        await store.refresh()
        #expect(state() == .merging)

        // マージし終えた（司令塔が epic をマージ済みにする前）: マージ中のまま出す
        let outputs = #"{"pullRequest":512,"commit":"\#(Self.mergeCommit)","branch":"askhub/\#(Self.epicID)"}"#
        await put(Self.flowMerge(state: "succeeded"), in: fixture.store)
        await put(Self.flowAttempt(outcome: "succeeded", outputs: outputs), in: fixture.store)
        await store.refresh()
        #expect(state() == .merging)

        // 司令塔が片付けを作り、epic をマージ済みにしてマージの記録を書いた
        let reference = #"{"keyId":"\#(fixture.key.keyID.rawValue)","nonce":"\#(approval.nonce.rawValue)"}"#
        let record = #"{"commit":"\#(Self.mergeCommit)","approval":\#(reference),"at":"2027-01-15T07:58:00Z"}"#
        let cleanUp = Self.finalJob(
            Self.flowCleanUpID,
            kind: "cleanUp",
            state: "assigned",
            attempts: 0,
            dependsOn: [Self.flowMergeID],
            at: "07:58"
        )
        await put(cleanUp, in: fixture.store)
        await put(["\(Self.finalBase)/epic.json": Self.flowEpic(stage: "merged", merge: record, updatedAt: "07:58")], in: fixture.store)
        await store.refresh()
        let merged = FinalReview.State.merged(at: Self.flowDate("07:58"), automatic: false)
        #expect(state() == merged)
        #expect(store.epic(Self.epicID)?.stage == .done)

        // 読み直しても、マージ済みのまま
        await store.refresh()
        #expect(state() == merged)
        #expect(service.snapshot(overlaying: [])?.epic(Self.epicID)?.finalReview?.state == merged)
    }

    /// 承認した head を固定したマージのジョブ（最後のレビューの後）
    private static func flowMerge(state: String, attempts: Int = 1) -> [String: String] {
        finalJob(
            flowMergeID,
            kind: "mergeFinalPullRequest",
            state: state,
            attempts: attempts,
            dependsOn: [reviewID],
            input: pullRequestInput(),
            at: "07:45"
        )
    }

    /// マージのジョブの試行（1 回目）
    private static func flowAttempt(outcome: String, outputs: String) -> [String: String] {
        let ended = outcome == "running" ? "null" : #""2027-01-15T07:57:00Z""#
        return [
            "\(finalBase)/attempts/\(flowMergeID)/1.json": """
            {"v":1,"job":"\(flowMergeID)","n":1,"mac":"mac-mini","startedAt":"2027-01-15T07:46:00Z","heartbeatAt":"2027-01-15T07:56:00Z",
             "endedAt":\(ended),"outcome":"\(outcome)","failure":null,"outputs":\(outputs)}
            """
        ]
    }
}
