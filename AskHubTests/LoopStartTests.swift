@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 「回答を確定してループを始める」（Discussion #1 の Q3）
@MainActor
struct LoopStartTests {
    /// 投稿したことにする
    private struct AcceptingPoster: AnswerPosting {
        func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL {
            question.comment.url
        }
    }

    /// 印を付けた Discussion を記録する。失敗させることもできる
    private final class RecordingStarter: LoopStarting {
        private let state = OSAllocatedUnfairLock<(marked: [String], fails: Bool)>(initialState: ([], false))

        var marked: [String] {
            state.withLock { $0.marked }
        }

        func setFails(_ fails: Bool) {
            state.withLock { $0.fails = fails }
        }

        func markReadyForLoop(_ discussion: InboxSubject) async throws {
            try state.withLock { state in
                if state.fails {
                    throw GitHubError.http(status: 403, message: "Resource not accessible by personal access token")
                }
                state.marked.append(discussion.nodeID)
            }
        }
    }

    private func makeInbox(starter: RecordingStarter) async -> InboxModel {
        let inbox = InboxModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeSource: { _ in SampleInboxSource() },
            makePoster: { _ in AcceptingPoster() },
            makeStarter: { _ in starter }
        )
        await inbox.refresh()
        return inbox
    }

    /// サンプルの Discussion（notti-ios#12）には質問が 2 つある
    private func discussionQuestions(in inbox: InboxModel) -> [InboxQuestion] {
        inbox.questions.filter { $0.subject.kind == .discussion }
    }

    @Test func canStartLoopOnlyForLastQuestionOfDiscussion() async throws {
        let inbox = await makeInbox(starter: RecordingStarter())
        let questions = discussionQuestions(in: inbox)
        #expect(questions.count == 2)
        #expect(!AnswerFormModel(question: questions[0]).canStartLoop(in: inbox))
        #expect(inbox.remainingQuestions(besides: questions[0]) == 1)

        // 1 つ目に答えると、残りの 1 つが最後になる
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])
        #expect(AnswerFormModel(question: questions[1]).canStartLoop(in: inbox))

        // PR の ask では選べない
        let ask = try #require(inbox.questions.first { $0.subject.kind == .pullRequest })
        #expect(!AnswerFormModel(question: ask).canStartLoop(in: inbox))
    }

    @Test func marksDiscussionReadyAfterPosting() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])

        let form = AnswerFormModel(question: questions[1])
        form.note = "朝だけにしたい"
        form.startsLoopAfterPosting = true
        await form.post(using: inbox)

        #expect(form.isPosted)
        #expect(!form.loopStartFailed)
        #expect(starter.marked == [questions[1].subject.nodeID])
    }

    @Test func doesNotMarkWithoutChoosingToStartLoop() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let form = AnswerFormModel(question: discussionQuestions(in: inbox)[0])
        form.choice = "1時間"
        await form.post(using: inbox)

        #expect(form.isPosted)
        #expect(starter.marked.isEmpty)
    }

    @Test func doesNotMarkWhileOtherQuestionsRemain() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let form = AnswerFormModel(question: discussionQuestions(in: inbox)[0])
        form.choice = "1時間"
        // 選べない状態で入っていても、ほかの未回答の質問が残っていれば始めない
        form.startsLoopAfterPosting = true
        await form.post(using: inbox)

        #expect(form.isPosted)
        #expect(starter.marked.isEmpty)
    }

    @Test func retriesMarkingWhenOnlyLoopStartFailed() async throws {
        let starter = RecordingStarter()
        starter.setFails(true)
        let inbox = await makeInbox(starter: starter)
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])
        let form = AnswerFormModel(question: questions[1])
        form.note = "朝だけにしたい"
        form.startsLoopAfterPosting = true
        await form.post(using: inbox)

        // 回答は投稿済みなので、印だけを付け直せるようにする
        #expect(form.isPosted)
        #expect(form.loopStartFailed)
        #expect(form.errorMessage?.hasPrefix("回答は投稿しました。ループを始める印（ready-for-loop）を付けられませんでした") == true)

        starter.setFails(false)
        await form.startLoop(using: inbox)
        #expect(!form.loopStartFailed)
        #expect(form.errorMessage == nil)
        #expect(starter.marked.count == 1)
    }
}
