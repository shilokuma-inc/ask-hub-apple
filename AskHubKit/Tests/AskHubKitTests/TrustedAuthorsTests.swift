@testable import AskHubKit
import Testing

struct TrustedAuthorsTests {
    private let trusted = TrustedAuthors(["mrs1669", "Partner"])
    private let questionBody = #"<!-- ask-hub:question id="q1" options="A|B" -->"#

    @Test func defaultTrustsOwner() {
        #expect(TrustedAuthors.default.contains("mrs1669"))
    }

    @Test func comparesLoginsCaseInsensitively() {
        #expect(trusted.contains("MRS1669"))
        #expect(trusted.contains("partner"))
        #expect(!trusted.contains("someone"))
        #expect(!trusted.contains(nil))
    }

    @Test func acceptsQuestionsOnlyFromTrustedAuthors() {
        #expect(trusted.question(in: questionBody, author: "mrs1669") == QuestionMarker(id: "q1", options: ["A", "B"]))
        #expect(trusted.question(in: questionBody, author: "someone") == nil)
        #expect(trusted.question(in: questionBody, author: nil) == nil)
        #expect(trusted.question(in: "目印なし", author: "mrs1669") == nil)
    }

    @Test func answeredWhenTrustedAuthorReplied() {
        #expect(trusted.isAnswered(replyAuthors: ["someone", "Partner"]))
        #expect(!trusted.isAnswered(replyAuthors: ["someone", nil]))
        #expect(!trusted.isAnswered(replyAuthors: [String?]()))
    }
}
