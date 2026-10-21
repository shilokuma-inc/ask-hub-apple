@testable import AskHubKit
import Testing

struct AnswerTests {
    @Test func bodyStartsWithChoiceLine() {
        #expect(Answer(choice: "1時間", note: "夜間はもっと長くてもよい。").body == "回答: 1時間\n夜間はもっと長くてもよい。")
        #expect(Answer(choice: "1時間").body == "回答: 1時間")
    }

    @Test func freeFormBodyHasNoChoiceLine() {
        #expect(Answer(note: "  自由記述だけ \n").body == "自由記述だけ")
    }

    private let choiceQuestion = QuestionMarker(id: "q1", options: ["1時間", "A", "B"])
    private let freeFormQuestion = QuestionMarker(id: "q2")

    @Test func parsesChoiceAndNote() {
        let answer = Answer(parsing: "回答: 1時間\r\n夜間はもっと長くてもよい。\r\n", for: choiceQuestion)
        #expect(answer == Answer(choice: "1時間", note: "夜間はもっと長くてもよい。"))
    }

    @Test func parsesFreeFormBody() {
        #expect(Answer(parsing: "このままで OK です", for: choiceQuestion) == Answer(note: "このままで OK です"))
        #expect(Answer(parsing: "このままで OK です", for: freeFormQuestion) == Answer(note: "このままで OK です"))
    }

    @Test func freeFormNoteStartingWithChoicePrefixIsNotAChoice() {
        let answer = Answer(note: "回答: 確認しました\n問題ありません")
        #expect(Answer(parsing: answer.body, for: freeFormQuestion) == answer)
        #expect(answer.isValid(for: freeFormQuestion))
    }

    @Test func bodyRoundTrips() {
        let answers = [
            (Answer(choice: "A", note: "1 行目\n2 行目"), choiceQuestion),
            (Answer(choice: "B"), choiceQuestion),
            (Answer(note: "自由記述"), freeFormQuestion)
        ]
        for (answer, marker) in answers {
            #expect(Answer(parsing: answer.body, for: marker) == answer)
        }
    }

    @Test func validatesAgainstOptions() {
        let marker = QuestionMarker(id: "q1", options: ["A", "B"])
        #expect(Answer(choice: "A").isValid(for: marker))
        #expect(!Answer(choice: "C").isValid(for: marker))
        #expect(!Answer(note: "選択肢なし").isValid(for: marker))
    }

    @Test func validatesFreeFormQuestion() {
        let marker = QuestionMarker(id: "q1")
        #expect(Answer(note: "自由記述").isValid(for: marker))
        #expect(!Answer(note: "  ").isValid(for: marker))
        #expect(!Answer(choice: "A", note: "自由記述").isValid(for: marker))
    }
}

struct AnswerAttachmentTests {
    private let choiceQuestion = QuestionMarker(id: "q1", options: ["A", "B"])
    private static let marker = AttachmentMarker(
        path: "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/design.png",
        sha: String(repeating: "b", count: 40),
        commit: String(repeating: "c", count: 40),
        name: "design.png",
        size: 2_048,
        type: "image/png"
    )

    private func answer(choice: String?, note: String) -> Answer {
        var answer = Answer(choice: choice, note: note)
        answer.attachments = [Self.marker]
        answer.attachmentRepository = "o/r"
        return answer
    }

    @Test func keepsChoiceLineFirstAndAppendsSectionAtEnd() {
        let body = answer(choice: "A", note: "補足です").body
        #expect(body.hasPrefix("回答: A\n補足です\n\n### 添付ファイル\n"))
        #expect(AttachmentMarker.parseAll(body) == [Self.marker])
        // オーケストレーター・ループ・ResumeWatcher の読み方で、選択肢が今までどおり読める
        #expect(Answer(parsing: body, for: choiceQuestion).choice == "A")
        #expect(Answer(parsing: body, for: choiceQuestion).note.hasPrefix("補足です"))
    }

    @Test func choiceOnlyAnswerWithAttachments() {
        let body = answer(choice: "B", note: "").body
        #expect(body.hasPrefix("回答: B\n\n### 添付ファイル\n"))
        #expect(Answer(parsing: body, for: choiceQuestion).choice == "B")
    }

    @Test func bodyWithoutAttachmentsIsUnchanged() {
        #expect(Answer(choice: "A", note: " 補足 ").body == "回答: A\n補足")
        // 添付だけでは投稿できない（今の isValid のまま）
        #expect(!answer(choice: nil, note: "").isValid(for: QuestionMarker(id: "q2")))
    }
}
