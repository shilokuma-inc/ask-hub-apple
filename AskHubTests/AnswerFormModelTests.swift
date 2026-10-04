@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// `GatedSource` の状態
private struct SourceGate {
    var calls = 0
    var opened = false
    var waiter: CheckedContinuation<Void, Never>?
}

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

    @Test func choiceLineMatchesFirstLineOfPostedBody() {
        let form = AnswerFormModel(question: question)
        #expect(form.answer.choiceLine == nil)
        form.choice = "1時間"
        form.note = "夜は長くてもよい"
        #expect(form.answer.choiceLine == "回答: 1時間")
        #expect(form.answer.body.split(separator: "\n").first.map(String.init) == form.answer.choiceLine)
    }

    @Test func freeFormAnswerHasNoChoiceLine() {
        #expect(Answer(note: "回答: 自由記述").choiceLine == nil)
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

    @Test func forgetsAnsweredQuestionsWhenTokenChanges() async throws {
        let store = InMemoryTokenStore(token: "github_pat_old")
        let inbox = InboxModel(tokenStore: store, makeSource: { _ in SampleInboxSource() }, makePoster: { _ in RecordingPoster() })
        await inbox.refresh()
        try await inbox.post(Answer(choice: "1時間"), to: question)
        #expect(!inbox.questions.contains { $0.id == question.id })

        // 別のトークン（別のアカウントかもしれない）に変えたら、回答済みの記録を捨てて GitHub の結果どおりに出す
        try store.save("github_pat_new")
        await inbox.refresh()
        #expect(inbox.questions.contains { $0.id == question.id })

        // 新しいトークンで回答した質問は、取り直しても戻さない
        try await inbox.post(Answer(choice: "1時間"), to: question)
        #expect(!inbox.questions.contains { $0.id == question.id })
    }

    /// 1 回目の取得を、テストが開けるまで止めておく取得元
    private final class GatedSource: InboxSource {
        private let gate = OSAllocatedUnfairLock(initialState: SourceGate())

        /// 待っている取得を進める。取得が待ち始める前に呼ばれても、待たずに進むようにする
        func open() {
            let waiter = gate.withLock { state in
                state.opened = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }

        func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
            let isFirst = gate.withLock { state in
                state.calls += 1
                return state.calls == 1
            }
            if isFirst {
                await withCheckedContinuation { continuation in
                    let opened = gate.withLock { state in
                        if !state.opened {
                            state.waiter = continuation
                        }
                        return state.opened
                    }
                    if opened {
                        continuation.resume()
                    }
                }
                // 古いトークンでの結果には質問が無い（回答済みの記録を消してしまう条件）
                return []
            }
            return try await SampleInboxSource().subjectsNeedingAnswer(org: org)
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            try await SampleInboxSource().questionThreads(of: subject)
        }

        func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
            []
        }
    }

    @Test func discardsResultFetchedWithOldTokenAfterAnsweringWithNewToken() async throws {
        let store = InMemoryTokenStore(token: "github_pat_old")
        let source = GatedSource()
        let inbox = InboxModel(tokenStore: store, makeSource: { _ in source }, makePoster: { _ in RecordingPoster() })

        let first = Task { await inbox.refresh() }
        while !inbox.isLoading {
            await Task.yield()
        }
        // 古いトークンで取得している間に、新しいトークンで回答した
        try store.save("github_pat_new")
        try await inbox.post(Answer(choice: "1時間"), to: question)
        source.open()
        await first.value

        // 古いトークンでの結果は捨て、新しいトークンで取り直しても回答した質問は戻らない
        #expect(inbox.state == .loaded)
        #expect(!inbox.questions.contains { $0.id == question.id })
        #expect(!inbox.questions.isEmpty)
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
