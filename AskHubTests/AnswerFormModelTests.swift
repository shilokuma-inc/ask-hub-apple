@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct AnswerFormModelTests {
    /// 投稿された回答を記録する。失敗させることもできる
    private final class RecordingPoster: AnswerPosting {
        private let posted = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let failure: (any Error & Sendable)?

        init(failure: (any Error & Sendable)? = nil) {
            self.failure = failure
        }

        var bodies: [String] {
            posted.withLock { $0 }
        }

        func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL {
            if let failure {
                throw failure
            }
            posted.withLock { $0.append(answer.body) }
            return question.comment.url
        }
    }

    private func makeInbox(token: String? = "github_pat_saved", poster: RecordingPoster) -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeSource: { _ in SampleInboxSource() },
            makePoster: { _ in poster }
        )
    }

    private let question = SampleInboxSource.sampleQuestion

    @Test func requiresChoiceForQuestionWithOptions() {
        let form = AnswerFormModel(question: question)
        #expect(!question.marker.isFreeForm)
        form.note = "補足だけ"
        #expect(!form.canPost)
        form.choice = question.marker.options[1]
        #expect(form.canPost)
        #expect(form.answer == Answer(choice: question.marker.options[1], note: "補足だけ"))
    }

    @Test func freeFormQuestionNeedsNote() {
        var freeForm = question
        freeForm.marker = QuestionMarker(id: "d12-q2")
        let form = AnswerFormModel(question: freeForm)
        #expect(!form.canPost)
        form.note = "通知は朝だけにしたい"
        #expect(form.canPost)
        #expect(form.answer == Answer(note: "通知は朝だけにしたい"))
    }

    @Test func postsAnswerInProtocolFormat() async {
        let poster = RecordingPoster()
        let inbox = makeInbox(poster: poster)
        await inbox.refresh()
        #expect(inbox.questions.contains { $0.id == question.id })

        let form = AnswerFormModel(question: question)
        form.choice = "1時間"
        form.note = "夜は長くてもよい"
        await form.post(using: inbox)

        #expect(form.isPosted)
        #expect(!form.canPost)
        #expect(poster.bodies == ["回答: 1時間\n夜は長くてもよい"])
        // 検索がまだ回答を反映していなくても（サンプルは同じ質問を返し続ける）、取り直した一覧に戻さない
        #expect(!inbox.questions.contains { $0.id == question.id })
        await inbox.refresh()
        #expect(!inbox.questions.contains { $0.id == question.id })
        #expect(inbox.questions.count == 2)
    }

    @Test func keepsInputAndShowsErrorWhenPostingFails() async {
        let poster = RecordingPoster(failure: GitHubError.http(status: 422, message: "Validation Failed"))
        let form = AnswerFormModel(question: question)
        form.choice = "1時間"
        await form.post(using: makeInbox(poster: poster))

        #expect(!form.isPosted)
        #expect(form.choice == "1時間")
        #expect(form.errorMessage == "GitHub とのやり取りに失敗しました（HTTP 422: Validation Failed）")
        #expect(form.canPost)
    }

    @Test func explainsMissingToken() async {
        let form = AnswerFormModel(question: question)
        form.choice = "1時間"
        await form.post(using: makeInbox(token: nil, poster: RecordingPoster()))
        #expect(form.errorMessage == "トークンが未設定です。設定で保存してください")
    }
}
