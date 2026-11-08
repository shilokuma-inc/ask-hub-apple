@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 実装の途中の質問: 開始する前の質問と同じカードで「あなたの番」に出し、どこで出た質問かを添える
extension StateClientServiceTests {
    private static let questionBase = "repos/\(repo)/epics/\(epicID)"
    private static let askingJobID = "01JCJ0B0000000000000000204"

    /// タスク 1 をマージし、タスク 2 の実装が質問で終えた epic（開始する前の q1 は回答済み、実装の途中の q2 は回答待ち）
    private static func askedEpic(
        stage: String = "running",
        task: String? = "t2",
        askingKind: String = "implementTask"
    ) -> [String: String] {
        let task = task.map { #""\#($0)""# } ?? "null"
        let options = #"[{"label":"名前順","effect":"探しやすい"},{"label":"登録順","effect":"新しいものが下に来る"}]"#
        return askingEpic(stage: stage, extra: [
            "\(questionBase)/epic.json": """
            {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
             "mac":"mac-mini","branch":"askhub/\(epicID)","finalPullRequest":null,"goalVersion":1,"origin":null,
             "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T06:00:00Z"}
            """,
            "\(questionBase)/goal.json": """
            {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
             "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"done"},
                      {"id":"t2","title":"一覧に出す","dependsOn":[],"state":"running"}],
             "humanTasks":[]}
            """,
            "\(questionBase)/questions.json": """
            {"v":1,"questions":[
              {"id":"q1","version":1,"title":"ランキングの単位","why":"集計と画面に関わる","options":\(options),
               "recommended":"名前順","reason":"今の仕組みのまま作れる","dependsOn":[],"round":1,"state":"answered","explanations":[],
               "answer":{"choice":"名前順","note":"","at":"2026-11-01T02:00:00Z",
                         "intent":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"}}},
              {"id":"q2","version":1,"title":"同点の並び","why":"同点のときの並びが決まっていない","options":\(options),
               "recommended":"名前順","reason":"探しやすい","dependsOn":[],"round":2,"state":"open","explanations":[],
               "job":"\(askingJobID)","task":\(task)}
            ]}
            """,
            "\(questionBase)/jobs/\(askingJobID).json": """
            {"v":1,"id":"\(askingJobID)","kind":"\(askingKind)","repo":"\(repo)","epic":"\(epicID)","task":\(task),"assignedMac":"mac-mini",
             "needs":{"claude":true,"build":true},"dependsOn":[],"state":"succeeded","attempts":1,"nextRunAt":null,"input":{},"origin":null,
             "createdAt":"2027-01-15T07:00:00Z","updatedAt":"2027-01-15T07:40:00Z"}
            """
        ])
    }

    @Test
    func questionDuringImplementationIsShownAsCardWithItsTask() async throws {
        let fixture = try makeService(files: Self.askedEpic())
        let snapshot = try await fixture.service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        let asked = try #require(epic.question("Q2"))
        #expect(asked.during == .task(number: 2, title: "一覧に出す"))
        #expect(asked.askedAt == ISO8601DateFormatter().date(from: "2027-01-15T07:40:00Z"))
        #expect(epic.question("Q1")?.during == nil)
        // 開始した後は、答えを待っている実装の途中の質問だけを出す（開始する前の質問は答え直せない）
        #expect(epic.awaitedQuestions.map(\.id) == ["Q2"])

        // 開始する前の質問と同じカードで「あなたの番」に出し、実装の途中の質問であることを札に添える
        let cards = DeckBuilder.cards(from: snapshot, scope: .all)
        let card = try #require(cards.first { $0.id == "\(Self.epicID)/question/Q2" })
        #expect(card.kindLabel == "実装の途中の質問 Q2")
        #expect(card.title == "同点の並び")
        #expect(card.choices.first?.label == "名前順")
        #expect(card.choices.first?.isRecommended == true)
        #expect(DeckBuilder.cards(from: snapshot, scope: .questions(Self.epicID)).map(\.id) == [card.id])

        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .questions })
        #expect(item.title == "実装の途中の質問に答える")
        #expect(item.detail == "タスク 2「一覧に出す」の実装の途中です。答えるまで止めて待っています")
        #expect(item.urgency == .blocking)
        let line = try #require(EpicStatus.lines(for: epic, in: snapshot, now: now).first)
        #expect(line.owner == .you)
        #expect(line.text == "タスク 2「一覧に出す」の実装の途中の質問の回答を待っています")
        // タスクは、質問の答えを待っている段階にする（レビューに進んだとは出さない）
        #expect(epic.tasks.map(\.state) == [.done(pullRequest: nil), .inProgress(.waitingForAnswer(question: "Q2"))])

        // 答えと説明の送り方は、開始する前と同じ（質問の版に結びつける）
        try await fixture.service.perform(.answer(epicID: Self.epicID, questionID: "Q2", optionID: "名前順", note: "同点は ID 順"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == AnswerIntent.kind)
        #expect(envelope.target?.id == "q2")
        #expect(envelope.targetVersion == "1")
        #expect(envelope.string("choice") == "名前順")
        #expect(envelope.string("note") == "同点は ID 順")
        // 処理を待つ間は回答した結果として出し、カードを出し続けない
        let sent = try await fixture.service.fetchSnapshot()
        #expect(DeckBuilder.cards(from: sent, scope: .all).isEmpty)
    }

    @Test
    func questionDuringFinalFixSaysSo() async throws {
        let files = Self.askedEpic(stage: "reviewing", task: nil, askingKind: "fixFinalPullRequest")
        let snapshot = try await makeService(files: files).service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.question("Q2")?.during == .finalPullRequest)
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .questions })
        #expect(item.detail == "最終 PR の直しの途中です。答えるまで止めて待っています")

        // 説明を待つ間・やめた epic では出さない
        var asked = files
        let pending = #""explanations":[{"asked":{"keyId":"\#(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000002"},"#
            + #""note":"名前順だと何が困る？","text":null,"at":"2027-01-15T07:45:00Z"}]"#
        asked["\(Self.questionBase)/questions.json"] = files["\(Self.questionBase)/questions.json"]?
            .replacingOccurrences(of: #""round":2,"state":"open","explanations":[]"#, with: #""round":2,"state":"clarifying","# + pending)
        let clarifying = try await makeService(files: asked).service.fetchSnapshot()
        #expect(clarifying.epic(Self.epicID)?.question("Q2")?.isAwaitingExplanation == true)
        #expect(DeckBuilder.cards(from: clarifying, scope: .all).isEmpty)
        let abandoned = Self.askedEpic(stage: "abandoned")
        #expect(DeckBuilder.cards(from: try await makeService(files: abandoned).service.fetchSnapshot(), scope: .all).isEmpty)
    }
}
