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

    @Test func parsesChoiceAndNote() {
        let answer = Answer(parsing: "回答: 1時間\r\n夜間はもっと長くてもよい。\r\n")
        #expect(answer == Answer(choice: "1時間", note: "夜間はもっと長くてもよい。"))
    }

    @Test func parsesFreeFormBody() {
        #expect(Answer(parsing: "このままで OK です") == Answer(note: "このままで OK です"))
    }

    @Test func bodyRoundTrips() {
        let answers = [
            Answer(choice: "A", note: "1 行目\n2 行目"),
            Answer(choice: "B"),
            Answer(note: "自由記述")
        ]
        for answer in answers {
            #expect(Answer(parsing: answer.body) == answer)
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
