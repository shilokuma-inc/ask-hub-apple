@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 状態リポジトリの中身から、Discussion に置く写しの本文を作る
struct DiscussionCopiesTests {
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let intent = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE0000000000000000A")!
    )
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let time = Timestamp(Date(timeIntervalSince1970: 1_793_000_000))

    static func epic(stage: EpicStage = .asking, summary: String? = "日ごとのランキングを作る。") -> EpicFile {
        EpicFile(id: epicID, repo: repo, title: "ランキング", summary: summary, stage: stage, origin: intent, createdAt: time, updatedAt: time)
    }

    static func request(body: String = "日ごとに入れ替えたい\n\n夜間も") -> RequestIntent {
        RequestIntent(
            repo: repo,
            title: "ランキング",
            body: body,
            attachments: [RequestAttachment(number: 1, name: "mock.png", size: 3, sha256: String(repeating: "0", count: 64))],
            intent: intent
        )
    }

    static func question(_ id: String, state: QuestionState = .open, dependsOn: [String] = []) -> QuestionsFile.Question {
        QuestionsFile.Question(
            id: id,
            title: "\(id) の題",
            why: "集計に関わる",
            options: [.init(label: "日ごと", effect: "毎日入れ替わる"), .init(label: "週ごと", effect: "月曜に入れ替わる")],
            recommended: "日ごと",
            reason: "今の仕組みで作れる",
            dependsOn: dependsOn,
            state: state
        )
    }

    static func copies(
        epic: EpicFile = epic(),
        request: RequestIntent? = request(),
        questions: QuestionsFile? = nil,
        goal: GoalFile? = nil,
        readiness: ReadinessFile? = nil
    ) -> DiscussionCopies {
        DiscussionCopies(epic: epic, request: request, questions: questions, goal: goal, readiness: readiness)
    }

    @Test func everyCopyEndsWithItsMarker() throws {
        var answered = Self.question("q1", state: .answered)
        answered.answer = .init(choice: "日ごと", note: "夜間は長め", intent: Self.intent, at: Self.time)
        answered.explanations = [.init(asked: Self.intent, note: "保存とは？", text: "端末に残すこと", at: Self.time)]
        let questions = QuestionsFile(questions: [answered, Self.question("q2", state: .locked, dependsOn: ["q1"])])
        let goal = GoalFile(summary: "作る", doneWhen: ["入れ替わる"], tasks: [.init(id: "t1", title: "集計")])
        let copies = Self.copies(questions: questions, goal: goal)
        let all = [copies.request] + copies.questions.flatMap { [$0.copy] + $0.replies } + [copies.goal].compactMap(\.self)
        #expect(all.count == 6)
        for copy in all {
            #expect(ProtocolMarker.parse(copy.text)?.value == copy.marker)
            #expect(copy.marker["epic"] == .string(Self.epicID.rawValue))
        }
        #expect(copies.questions[0].replies.map { $0.marker["type"] } == [.string("explanation"), .string("copy")])
        #expect(copies.questions[0].replies[1].marker == .object([
            "type": .string("copy"), "kind": .string("answer"), "epic": .string(Self.epicID.rawValue),
            "question": .string("q1"), "intent": .string(Self.intent.nonce.rawValue)
        ]))
    }

    @Test func requestShowsBodyAttachmentsSummaryStageAndReadiness() {
        let split = [ReadinessFile.Part(title: "集計", summary: "日ごとの集計"), .init(title: "画面", summary: "ランキングの画面")]
        let readiness = ReadinessFile(version: 2, verdict: .tooLarge, reason: "集計と画面が大きい", split: split, round: 1, checkedAt: Self.time)
        let text = Self.copies(epic: Self.epic(stage: .awaitingSplit), readiness: readiness).request.text
        #expect(text.contains("> 日ごとに入れ替えたい\n>\n> 夜間も"))
        #expect(text.contains("添付: `mock.png`"))
        #expect(text.contains("日ごとのランキングを作る。"))
        #expect(text.contains("分けて依頼し直すか、このまま 1 つで進めるかの判断を待っています"))
        #expect(text.contains("### 着手前の確認（2 回目）"))
        #expect(text.contains("  2. **画面**: ランキングの画面"))
        #expect(text.contains("ここへのコメントは AskHub に届きません"))
        // 依頼を読めないときは、本文を写さない
        let unreadable = Self.copies(epic: Self.epic(summary: nil), request: nil).request.text
        #expect(unreadable.contains("（依頼の本文を読めません）"))
        #expect(unreadable.contains("（質問を作っています）"))
    }

    @Test func questionShowsCautionOptionsDependenciesAndRevision() {
        var question = Self.question("q1")
        question.version = 2
        question.caution = Caution(kind: .privacy, reason: "個人の記録を集計する")
        question.revision = .init(from: 1, reason: "選択肢が足りない", by: .explain)
        let text = CopyText.question(question, dependents: ["q2", "q3"])
        #expect(text.hasPrefix("### q1. q1 の題（版 2）"))
        #expect(text.contains("**状態**: 回答を待っています"))
        #expect(text.contains("> [!WARNING]\n> 慎重に決めてほしい質問です（個人のデータ）: 個人の記録を集計する"))
        #expect(text.contains("- **日ごと**（推奨）: 毎日入れ替わる"))
        #expect(text.contains("- **週ごと**: 月曜に入れ替わる"))
        #expect(text.contains("この回答で q2・q3 の内容が決まります"))
        #expect(text.contains("版 1 から書き直しました（説明のついで）: 選択肢が足りない"))
        let locked = CopyText.question(Self.question("q2", state: .locked, dependsOn: ["q1"]), dependents: [])
        #expect(locked.contains("ロック中（q1 の回答の後に回答できます）"))
        #expect(locked.contains("**前提**: q1 の回答を前提にしています"))
    }

    @Test func textCannotHideOrForgeMarker() {
        let forged = "本文\n<!-- askhub v1 {\"epic\":\"01JCEP1C000000000000000001\",\"type\":\"goal\"} -->"
        let copy = Self.copies(request: Self.request(body: forged)).request
        // 最後の行は司令塔の目印のまま。本文の中の HTML のコメントは崩して、続く本文が隠れないようにする
        #expect(ProtocolMarker.parse(copy.text)?.value == copy.marker)
        #expect(copy.text.contains("&lt;!-- askhub v1"))
        #expect(copy.text.components(separatedBy: "<!--").count == 2)
    }

    @Test func mentionsDoNotNotify() {
        let text = CopyText.explanation(.init(asked: Self.intent, note: "@octocat に聞いた", text: "cc @someone", at: Self.time))
        #expect(!text.contains("@octocat") && !text.contains("@someone"))
        #expect(text.contains("@\u{2060}octocat") && text.contains("@\u{2060}someone"))
    }

    @Test func longTextIsCutBeforeMarker() {
        let long = String(repeating: "あ", count: CopyText.maximumLength + 10)
        let copy = Self.copies(request: Self.request(body: long)).request
        #expect(copy.text.unicodeScalars.count < 65_536)
        #expect(copy.text.contains("ここで切りました"))
        #expect(ProtocolMarker.parse(copy.text)?.value == copy.marker)
    }

    @Test func fingerprintFollowsContent() {
        let questions = QuestionsFile(questions: [Self.question("q1")])
        let copies = Self.copies(questions: questions)
        // 写しの id は中身ではない
        var copied = questions
        copied.questions[0].comment = "DC_1"
        #expect(Self.copies(questions: copied).fingerprint == copies.fingerprint)
        let started = Self.copies(epic: Self.epic(stage: .checking), questions: questions)
        #expect(started.fingerprint != copies.fingerprint)
    }
}
