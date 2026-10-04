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
