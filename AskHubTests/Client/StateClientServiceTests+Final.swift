@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 最終 PR: 判断のカード・マージの規則・チェックの組み立てと、判断への答え・マージの承認・最終 PR への指示の送り方
extension StateClientServiceTests {
    private static let finalBase = "repos/\(repo)/epics/\(epicID)"
    private static let finalHead = "1111111111111111111111111111111111111111"
    private static let finalNewHead = "2222222222222222222222222222222222222222"
    private static let openID = "01JCJ0F0000000000000000201"
    private static let reviewID = "01JCJ0F0000000000000000202"
    private static let fixID = "01JCJ0F0000000000000000203"
    private static let secondReviewID = "01JCJ0F0000000000000000204"
    private static let mergeID = "01JCJ0F0000000000000000205"
    private static let sensitiveReason = ".github/workflows の差分"

    private static func finalEpic(stage: String) -> String {
        """
        {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
         "mac":"mac-mini","branch":"askhub/\(epicID)","finalPullRequest":512,"goalVersion":1,"origin":null,
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T07:40:00Z"}
        """
    }

    private static let doneGoal = """
    {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
     "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"done"},{"id":"t2","title":"一覧に出す","dependsOn":[],"state":"done"}],
     "humanTasks":[]}
    """

    /// 答えの意図の鍵（KeyID は 43 文字。形が違うと判断の一覧ごと読めない）
    private static let answerKey = String(repeating: "k", count: 43)

    /// 見える仮決め（d1・d4: 答え待ち、d2: OK 済み）と内部の細部（d3）
    private static let decisions = """
    {"v":1,"items":[
      {"id":"d1","task":"t2","pullRequest":41,"visible":true,"what":"見出しを短くした","why":"iPhone の幅に収める","alternatives":["2 行にする"]},
      {"id":"d2","task":"t2","pullRequest":41,"visible":true,"what":"順位を太字にした","why":"一目で分かる","alternatives":[],
       "answer":{"choice":"ok","note":"","intent":{"keyId":"\(answerKey)","nonce":"01JCJ0F0000000000000000299"},
                 "at":"2027-01-15T07:30:00Z"}},
      {"id":"d3","task":"t1","pullRequest":40,"visible":false,"what":"集計は UTC の日付で区切る","why":"サーバーと合わせる","alternatives":[]},
      {"id":"d4","task":"t1","visible":true,"what":"空のときに案内を出す","why":"初回に迷わない","alternatives":[]}
    ]}
    """

    private static func finalJob(
        _ id: String,
        kind: String,
        state: String = "succeeded",
        attempts: Int = 1,
        dependsOn: [String] = [],
        input: String = "{}",
        at time: String
    ) -> [String: String] {
        let dependsOn = dependsOn.map { #""\#($0)""# }.joined(separator: ",")
        return [
            "\(finalBase)/jobs/\(id).json": """
            {"v":1,"id":"\(id)","kind":"\(kind)","repo":"\(repo)","epic":"\(epicID)","task":null,"assignedMac":"mac-mini",
             "needs":{"claude":true,"build":false},"dependsOn":[\(dependsOn)],"state":"\(state)","attempts":\(attempts),
             "nextRunAt":null,"input":\(input),"origin":null,
             "createdAt":"2027-01-15T\(time):00Z","updatedAt":"2027-01-15T\(time):30Z"}
            """
        ]
    }

    private static func finalAttempt(_ job: String, outcome: String = "succeeded", outputs: String) -> [String: String] {
        let ended = outcome == "running" ? "null" : #""2027-01-15T07:35:00Z""#
        return [
            "\(finalBase)/attempts/\(job)/1.json": """
            {"v":1,"job":"\(job)","n":1,"mac":"mac-mini","startedAt":"2027-01-15T07:20:00Z","heartbeatAt":"2027-01-15T07:56:00Z",
             "endedAt":\(ended),"outcome":"\(outcome)","failure":null,"outputs":\(outputs)}
            """
        ]
    }

    private static func pullRequestInput(head: String = finalHead, reason: String? = nil) -> String {
        let reason = reason.map { #","reason":"\#($0)""# } ?? ""
        return #"{"pullRequest":512,"head":"\#(head)"\#(reason)}"#
    }

    /// 最終 PR のレビューが通り、人の確認とマージを待っている epic（`.github/` に差分があるので手動のマージ）
    private static func reviewingEpic(stage: String = "reviewing", extra: [[String: String]] = []) -> [String: String] {
        var files = askingEpic(extra: [
            "\(finalBase)/epic.json": finalEpic(stage: stage),
            "\(finalBase)/goal.json": doneGoal,
            "\(finalBase)/decisions.json": decisions
        ])
        let parts = [
            finalJob(openID, kind: "openFinalPullRequest", at: "07:00"),
            finalJob(reviewID, kind: "reviewFinalPullRequest", dependsOn: [openID], input: pullRequestInput(), at: "07:10"),
            finalAttempt(reviewID, outputs: #"{"verdict":"ready","mergeRisks":[{"kind":"sensitivePaths","reason":"\#(sensitiveReason)"}]}"#)
        ] + extra
        for part in parts {
            files.merge(part) { _, new in new }
        }
        return files
    }

    private func put(_ files: [String: String], in store: InMemoryStateStore) async {
        for (path, text) in files {
            await store.put(path, data: Data(text.utf8))
        }
    }

    private func sentEnvelopes(in fixture: Fixture) async throws -> [IntentEnvelope] {
        struct Stored: Decodable {
            var envelope: IntentEnvelope
        }
        let entries = try await fixture.store.listAll("\(StatePath.intents)/\(fixture.key.keyID.rawValue)") ?? []
        var envelopes: [IntentEnvelope] = []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let data = try #require(await fixture.store.data(at: entry.path))
            envelopes.append(try JSONDecoder().decode(Stored.self, from: data).envelope)
        }
        return envelopes
    }

    // MARK: 組み立て

    /// 人の確認を待つ最終 PR: 見える仮決めをカードに、内部の細部を畳む一覧にし、マージの規則は司令塔と同じ判定で出す
    @Test
    func reviewingEpicBuildsFinalReview() async throws {
        let service = try makeService(files: Self.reviewingEpic()).service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.stage == .finalReview)
        let review = try #require(epic.finalReview)
        #expect(review.pullRequestNumber == 512)
        #expect(review.headCommit == Self.finalHead)
        // 追加・削除の行数は状態リポジトリに無いので出さない
        #expect(review.lineChanges == nil)
        #expect(review.state == .reviewable)
        #expect(review.checks.ci == .passed)
        #expect(review.checks.findings == nil)
        #expect(review.mergePolicy == .manual([.visibleDecisions(count: 3), .sensitivePaths([Self.sensitiveReason])]))
        #expect(review.decisions.map(\.id) == ["d1", "d2", "d4"])
        #expect(review.decisions.map(\.response) == [.pending, .accepted, .pending])
        #expect(review.internalDecisions == ["集計は UTC の日付で区切る"])
        let first = try #require(review.decisions.first)
        #expect(first.title == "見出しを短くした")
        #expect(first.goalSource == "タスク 2「一覧に出す」 · 子 PR #41")
        #expect(first.alternatives == ["2 行にする"])
        #expect(first.before == nil && first.after == nil)
        #expect(first.screenshotNote == "スクショ無し（このリポジトリには撮影の設定が無い）")
        // 答えていないカードがある間は、承認を受け付けない
        #expect(!review.acceptsApproval)
        #expect(!review.canMerge)
        #expect(epic.history.contains { $0.text == "最終 PR #512 を出しました" })

        // 「あなたの番」とデッキに出す
        let line = EpicStatus.lines(for: epic, in: snapshot, now: now).first
        #expect(line?.owner == .you)
        #expect(line?.text == "判断 2 件の確認を待っています")
        #expect(InboxBuilder.items(from: snapshot, now: now).contains { $0.kind == .finalReview && $0.route == .finalReview(Self.epicID) })
        #expect(DeckBuilder.cards(from: snapshot, scope: .decisions(Self.epicID)).map(\.title) == ["見出しを短くした", "空のときに案内を出す"])
    }

    /// 判断のカードへの答えは、最後に読んだ head を対象の版にして送る。処理を待つ間は答えた結果として出し、承認できるかにも当てる
    @Test
    func decisionAnswerIsSignedWithHeadAndShownUntilProcessed() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        #expect(service.supports(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: .accept)))
        let fix = DecisionReply.fix("見出しを元の長さに戻して")
        try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: fix))

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == DecisionIntent.kind)
        #expect(envelope.target == IntentEnvelope.Target(type: DecisionTarget.targetType, epic: ULID(rawValue: Self.epicID), id: "d1"))
        #expect(envelope.targetVersion == Self.finalHead)
        #expect(envelope.string("answer") == "fix")
        #expect(envelope.string("note") == "見出しを元の長さに戻して")

        let snapshot = try await service.fetchSnapshot()
        let review = try #require(snapshot.epic(Self.epicID)?.finalReview)
        #expect(review.decisions.first { $0.id == "d1" }?.response == .fixing(request: "見出しを元の長さに戻して"))
        #expect(snapshot.sentIntents.first?.title == "判断「見出しを短くした」への回答 · ランキング")
        // 別案・直してほしいは本文が要る
        await #expect(throws: ClientServiceError.self) {
            let blank = DecisionReply.alternative(" ")
            try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d4", headCommit: Self.finalHead, reply: blank))
        }
        // カードに無い判断（内部の細部）には答えない
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d3", headCommit: Self.finalHead, reply: .accept))
        }
        // 同じカードへの答え直しは司令塔が断るので、最初の答えのまま出す
        try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: .accept))
        let again = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.finalReview)
        #expect(again.decisions.first { $0.id == "d1" }?.response == .fixing(request: "見出しを元の長さに戻して"))
    }

    /// 仕分ける前の仮決めはカードに出してマージの規則に数えるが、司令塔が受け付けないので答えは送らない。
    /// 最終 PR の直しで足した仮決めは最終 PR の番号を出し、通ったレビューがマージの規則の材料を返さなければ手動のマージにする
    @Test
    func unclassifiedDecisionIsShownButNotAnswered() async throws {
        let decisions = """
        {"v":1,"items":[
          {"id":"d1","task":"t2","pullRequest":41,"visible":true,"what":"見出しを短くした","why":"iPhone の幅に収める","alternatives":[]},
          {"id":"d5","task":"t2","pullRequest":512,"visible":null,"what":"余白を詰めた","why":"指示に合わせた","alternatives":[]}
        ]}
        """
        let readyWithoutRisks = Self.finalAttempt(Self.reviewID, outputs: #"{"verdict":"ready"}"#)
        let decisionsFile = ["\(Self.finalBase)/decisions.json": decisions]
        let fixture = try makeService(files: Self.reviewingEpic(extra: [decisionsFile, readyWithoutRisks]))
        let service = fixture.service
        let review = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.finalReview)
        #expect(review.decisions.map(\.id) == ["d1", "d5"])
        #expect(review.decisions.last?.goalSource == "タスク 2「一覧に出す」 · 最終 PR #512")
        #expect(review.mergePolicy == .manual([.visibleDecisions(count: 2), .risksUnknown]))
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d5", headCommit: Self.finalHead, reply: .accept))
        }

        try await service.perform(.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.finalHead, decisionIDs: ["d1", "d5"]))
        let sent = try await sentEnvelopes(in: fixture)
        #expect(sent.map { $0.target?.id } == ["d1"])
        let answered = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.finalReview)
        // 仕分ける前の仮決めがある間は、承認を受け付けない（`FinalMergeRule.canApprove`）
        #expect(!answered.acceptsApproval)
        #expect(!answered.canMerge)
    }

    /// まとめて OK は、答えの無いカードそれぞれに OK を送る。答え終えたら承認でき、承認は見た head に結びつけて送る
    @Test
    func acceptAllThenApproveMerge() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        // 答えていないカードがある間は、承認を送らない
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.merge(epicID: Self.epicID, headCommit: Self.finalHead))
        }
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.finalHead, decisionIDs: ["d1", "d4"])
        try await service.perform(acceptAll)
        // 読み直す前にもう一度押しても、送ってあって受け取り待ちの答えは送り直さない
        try await service.perform(acceptAll)
        let answers = try await sentEnvelopes(in: fixture)
        #expect(answers.map(\.kind) == [DecisionIntent.kind, DecisionIntent.kind])
        #expect(answers.map { $0.target?.id } == ["d1", "d4"])
        #expect(answers.allSatisfy { $0.string("answer") == "ok" && $0.targetVersion == Self.finalHead })
        #expect(service.lastSend(of: acceptAll)?.isWaiting == true)

        let answered = try await service.fetchSnapshot()
        let review = try #require(answered.epic(Self.epicID)?.finalReview)
        // #expect の中で key path の関数を渡すと、マクロの展開で throws の扱いが合わないので外で求める
        let allConfirmed = review.decisions.allSatisfy(\.isConfirmed)
        #expect(allConfirmed)
        #expect(review.acceptsApproval)
        #expect(review.canMerge)
        let waiting = try #require(answered.epic(Self.epicID))
        #expect(EpicStatus.lines(for: waiting, in: answered, now: now).first?.text == "マージを待っています")

        try await service.perform(.merge(epicID: Self.epicID, headCommit: Self.finalHead))
        let approval = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(approval.kind == ApproveMergeIntent.kind)
        #expect(approval.target == IntentEnvelope.Target(type: FinalPullRequestTarget.targetType, epic: ULID(rawValue: Self.epicID)))
        #expect(approval.targetVersion == Self.finalHead)
        #expect(approval.payload?.isEmpty != false)
        // 司令塔は番号の順に処理するので、承認は答えより後の番号で送る（同じ時刻に送っても）
        #expect(answers.allSatisfy { $0.nonce < approval.nonce })

        let merging = try await service.fetchSnapshot()
        let epic = try #require(merging.epic(Self.epicID))
        #expect(epic.finalReview?.state == .merging)
        #expect(EpicStatus.lines(for: epic, in: merging, now: now).first?.text == "マージの承認を送りました。司令塔が受け取るのを待っています")
        #expect(!InboxBuilder.items(from: merging, now: now).contains { $0.kind == .finalReview })
    }

    /// 最終 PR への指示は、見た head に結びつけて送る。処理を待つ間は機械の番として出し、判断の確認とマージを止める
    @Test
    func finalInstructionIsSignedWithSeenHead() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.instructFinal(epicID: Self.epicID, headCommit: Self.finalHead, instruction: "  "))
        }
        try await service.perform(.instructFinal(epicID: Self.epicID, headCommit: Self.finalHead, instruction: "ボタンの色を元に戻して"))

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == InstructFinalIntent.kind)
        #expect(envelope.target == IntentEnvelope.Target(type: FinalPullRequestTarget.targetType, epic: ULID(rawValue: Self.epicID)))
        #expect(envelope.targetVersion == Self.finalHead)
        #expect(envelope.string("instruction") == "ボタンの色を元に戻して")

        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.finalReview?.state == .checking)
        // 前のレビューの結果（CI は通りました）を、今の結果として出さない
        #expect(epic.finalReview?.checks.ci == .fixingByRequest)
        #expect(EpicStatus.lines(for: epic, in: snapshot, now: now).first?.text == "最終 PR への指示を送りました。司令塔が受け取るのを待っています")
        #expect(!InboxBuilder.items(from: snapshot, now: now).contains { $0.kind == .finalReview })
        #expect(DeckBuilder.cards(from: snapshot, scope: .decisions(Self.epicID)).isEmpty)
        #expect(snapshot.sentIntents.first?.title == "最終 PR への指示 · ランキング")
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

    /// 送った後に head が変わったら（直しが push された）、送った答えは司令塔が断るので、答えた結果として出さない
    @Test
    func answerForOldHeadIsNotShown() async throws {
        let fixture = try makeService(files: Self.reviewingEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: .accept))
        #expect(try await service.fetchSnapshot().epic(Self.epicID)?.finalReview?.decisions.first?.response == .accepted)

        await put(Self.finalJob(
            Self.secondReviewID,
            kind: "reviewFinalPullRequest",
            dependsOn: [Self.reviewID],
            input: Self.pullRequestInput(head: Self.finalNewHead),
            at: "07:50"
        ), in: fixture.store)
        let review = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.finalReview)
        #expect(review.headCommit == Self.finalNewHead)
        #expect(review.decisions.first?.response == .pending)
    }

    // MARK: 機械が進めている間

    /// 最終 PR の直しの間は、機械の番として段取りとチェックを出す（判断の確認とマージはまだできない）。直すことは最後のレビューの findings から出す
    @Test
    func finalizingEpicShowsFixAndChecks() async throws {
        let failedReview = Self.finalAttempt(Self.reviewID, outputs: #"{"verdict":"fixCI","findings":"UI テストが落ちた"}"#)
        let fixing = Self.finalJob(
            Self.fixID,
            kind: "fixFinalPullRequest",
            state: "running",
            dependsOn: [Self.reviewID],
            input: Self.pullRequestInput(reason: "ci"),
            at: "07:40"
        )
        let running = Self.finalAttempt(Self.fixID, outcome: "running", outputs: "null")
        let fixture = try makeService(files: Self.reviewingEpic(stage: "finalizing", extra: [failedReview, fixing, running]))
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        let review = try #require(epic.finalReview)
        #expect(review.state == .checking)
        #expect(review.checks.ci == .fixing(.build, attempt: 1))
        #expect(review.checks.findings == "UI テストが落ちた")
        #expect(epic.activities.map(\.kind) == [.step(.final(.fixing(pullRequest: 512, reason: .checks(round: 1))), .running(attempt: 1))])
        let line = EpicStatus.lines(for: epic, in: snapshot, now: now).first
        #expect(line?.owner == .machine)
        #expect(line?.text == "mac-mini で最終 PR #512 の CI の失敗を直しています（1 回目）")
        #expect(!InboxBuilder.items(from: snapshot, now: now).contains { $0.kind == .finalReview })
        #expect(DeckBuilder.cards(from: snapshot, scope: .decisions(Self.epicID)).isEmpty)
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.respondToDecision(epicID: Self.epicID, decisionID: "d1", headCommit: Self.finalHead, reply: .accept))
        }

        // 直し終えて、次のレビューが動いている
        let ciFix = Self.pullRequestInput(reason: "ci")
        let fixed = Self.finalJob(Self.fixID, kind: "fixFinalPullRequest", dependsOn: [Self.reviewID], input: ciFix, at: "07:40")
        await put(fixed, in: fixture.store)
        await put(Self.finalJob(
            Self.secondReviewID,
            kind: "reviewFinalPullRequest",
            state: "running",
            dependsOn: [Self.fixID],
            input: Self.pullRequestInput(head: Self.finalNewHead),
            at: "07:50"
        ), in: fixture.store)
        await put(Self.finalAttempt(Self.secondReviewID, outcome: "running", outputs: "null"), in: fixture.store)
        let reviewing = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(reviewing.finalReview?.headCommit == Self.finalNewHead)
        #expect(reviewing.finalReview?.checks.ci == .reviewing)
        #expect(reviewing.finalReview?.checks.findings == nil)
        #expect(reviewing.activities.map(\.kind) == [.step(.final(.reviewing(pullRequest: 512)), .running(attempt: 1))])
    }

    /// マージのジョブが動いている間はマージ中、マージした epic は、人が承認したか（承認を送った・見える仮決めがあった）で出し分ける
    @Test
    func mergingAndMergedStates() async throws {
        let input = Self.pullRequestInput()
        let mergeJob = Self.finalJob(Self.mergeID, kind: "mergeFinalPullRequest", state: "running", input: input, at: "07:45")
        let merging = try makeService(files: Self.reviewingEpic(extra: [mergeJob])).service
        let mergingEpic = try #require(try await merging.fetchSnapshot().epic(Self.epicID))
        #expect(mergingEpic.finalReview?.state == .merging)
        #expect(mergingEpic.activities.map(\.kind) == [.step(.final(.merging(pullRequest: 512)), .running(attempt: 1))])

        let merged = try makeService(files: Self.reviewingEpic(stage: "merged")).service
        let mergedSnapshot = try await merged.fetchSnapshot()
        let mergedEpic = try #require(mergedSnapshot.epic(Self.epicID))
        #expect(mergedEpic.stage == .done)
        #expect(mergedEpic.finalReview?.state == .merged(at: Self.finalDate("07:40"), automatic: false))
        #expect(EpicStatus.lines(for: mergedEpic, in: mergedSnapshot, now: now).first?.text == "マージしました")
        #expect(mergedEpic.history.contains { $0.text == "最終 PR #512 をマージしました" })

        // 見える仮決めが無く、承認も送っていなければ、自動でマージした
        let internalOnly = #"{"v":1,"items":[{"id":"d3","task":"t1","visible":false,"what":"集計は UTC","why":"合わせる","alternatives":[]}]}"#
        let decisionsPath = "\(Self.finalBase)/decisions.json"
        let automatic = try makeService(files: Self.reviewingEpic(stage: "merged", extra: [[decisionsPath: internalOnly]]))
        let automaticSnapshot = try await automatic.service.fetchSnapshot()
        let automaticEpic = try #require(automaticSnapshot.epic(Self.epicID))
        #expect(automaticEpic.finalReview?.state == .merged(at: Self.finalDate("07:40"), automatic: true))
        #expect(EpicStatus.lines(for: automaticEpic, in: automaticSnapshot, now: now).first?.text == "自動でマージしました")
    }

    /// 判断の一覧を読めないときは、空の一覧と区別して手動のマージにし、承認を送らない
    @Test
    func unreadableDecisionsBlockApproval() async throws {
        let broken = ["\(Self.finalBase)/decisions.json": #"{"v":1,"items":[{"id":"d1"}]}"#]
        let service = try makeService(files: Self.reviewingEpic(extra: [broken])).service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.contains { $0.source == "\(Self.finalBase)/decisions.json" })
        let review = try #require(snapshot.epic(Self.epicID)?.finalReview)
        #expect(review.decisions.isEmpty)
        #expect(review.mergePolicy == .manual([.sensitivePaths([Self.sensitiveReason]), .decisionsUnreadable]))
        #expect(!review.acceptsApproval)
        #expect(!review.canMerge)
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.merge(epicID: Self.epicID, headCommit: Self.finalHead))
        }
    }

    private static func finalDate(_ time: String) -> Date {
        ISO8601DateFormatter().date(from: "2027-01-15T\(time):00Z") ?? .distantPast
    }
}
