@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// `RecordingStarter` が記録した内容
private struct RecordingStarterState {
    /// `ready-for-loop` を付けた Discussion
    var marked: [String] = []
    /// `manual-loop` を付けた Discussion
    var manual: [String] = []
    var fails = false
}

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
        private let state = OSAllocatedUnfairLock(initialState: RecordingStarterState())

        var marked: [String] {
            state.withLock { $0.marked }
        }

        var markedManual: [String] {
            state.withLock { $0.manual }
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

        func markManualLoop(_ discussion: InboxSubject) async throws {
            try state.withLock { state in
                if state.fails {
                    throw GitHubError.http(status: 403, message: "Resource not accessible by personal access token")
                }
                state.manual.append(discussion.nodeID)
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
        inbox.questions.filter { $0.subject.shortReference == "notti-ios#12" }
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

    /// テストごとに別の UserDefaults を使い、端末に保存された設定に左右されないようにする
    private func makeDefaults(startsLoopAfterPosting: Bool?) throws -> UserDefaults {
        let suiteName = "LoopStartTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        if let startsLoopAfterPosting {
            defaults.set(startsLoopAfterPosting, forKey: LoopStartPreference.defaultsKey)
        }
        return defaults
    }

    @Test func startsLoopByDefaultOnlyForLastQuestionOfDiscussion() async throws {
        let defaults = try makeDefaults(startsLoopAfterPosting: true)
        let inbox = await makeInbox(starter: RecordingStarter())
        let questions = discussionQuestions(in: inbox)
        #expect(!AnswerFormModel(question: questions[0], inbox: inbox, defaults: defaults).startsLoopAfterPosting)

        // 1 つ目に答えると、最後の質問では既定でオンになる
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])
        #expect(AnswerFormModel(question: questions[1], inbox: inbox, defaults: defaults).startsLoopAfterPosting)

        // PR の ask ではオンにしない
        let ask = try #require(inbox.questions.first { $0.subject.kind == .pullRequest })
        #expect(!AnswerFormModel(question: ask, inbox: inbox, defaults: defaults).startsLoopAfterPosting)
    }

    @Test func doesNotStartLoopByDefaultWhenSettingIsOff() async throws {
        let defaults = try makeDefaults(startsLoopAfterPosting: false)
        let inbox = await makeInbox(starter: RecordingStarter())
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])

        // 設定画面でオフにしていれば、最後の質問でもオフから始める。トグルは出るので、オンにはできる
        let form = AnswerFormModel(question: questions[1], inbox: inbox, defaults: defaults)
        #expect(!form.startsLoopAfterPosting)
        #expect(form.canStartLoop(in: inbox))
    }

    @Test func loopStartPreferenceIsOnUntilChanged() throws {
        let defaults = try makeDefaults(startsLoopAfterPosting: nil)
        #expect(LoopStartPreference.startsLoopAfterPosting(in: defaults))

        defaults.set(false, forKey: LoopStartPreference.defaultsKey)
        #expect(!LoopStartPreference.startsLoopAfterPosting(in: defaults))

        // 既定値に戻すと、またオンになる
        LoopStartPreference.reset(in: defaults)
        #expect(LoopStartPreference.startsLoopAfterPosting(in: defaults))
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

    @Test func marksDiscussionManualInsteadOfReadyWhenRunningByHand() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])

        let form = AnswerFormModel(question: questions[1])
        // 既定はオーケストレーターで始める
        #expect(form.loopRunner == .orchestrator)
        form.note = "朝だけにしたい"
        form.startsLoopAfterPosting = true
        form.loopRunner = .manual
        await form.post(using: inbox)

        // manual-loop だけを付け、ready-for-loop は付けない
        #expect(form.isPosted)
        #expect(!form.loopStartFailed)
        #expect(starter.markedManual == [questions[1].subject.nodeID])
        #expect(starter.marked.isEmpty)
        // Claude Code に渡す指示を出す
        let subject = questions[1].subject
        #expect(form.manualLoopInstruction == ManualLoopInstruction.make(repository: subject.repository, discussionNumber: subject.number))
    }

    @Test func retriesManualMarkWhenItFailed() async throws {
        let starter = RecordingStarter()
        starter.setFails(true)
        let inbox = await makeInbox(starter: starter)
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])
        let form = AnswerFormModel(question: questions[1])
        form.note = "朝だけにしたい"
        form.startsLoopAfterPosting = true
        form.loopRunner = .manual
        await form.post(using: inbox)

        // 付けられなければ画面を閉じずに再試行できるようにする（オーケストレーターで始めるときと同じ）
        #expect(form.isPosted)
        #expect(form.loopStartFailed)
        #expect(form.errorMessage?.hasPrefix("回答は投稿しました。手で回す印（manual-loop）を付けられませんでした") == true)
        // 印を付けられるまでは、指示を出さない
        #expect(form.manualLoopInstruction == nil)

        // 投稿の後に回し方を選び直しても、投稿を始めたときの回し方で付け直す
        form.loopRunner = .orchestrator
        starter.setFails(false)
        await form.startLoop(using: inbox)
        #expect(!form.loopStartFailed)
        #expect(starter.markedManual.count == 1)
        #expect(starter.marked.isEmpty)
        #expect(form.manualLoopInstruction != nil)
    }

    @Test func postsAnswerWhenManualChosenButOtherQuestionsRemain() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        // 手動を選んだ後に、同じ Discussion の未回答の質問が増えた（一覧の取り直し）場合と同じ状態
        let form = AnswerFormModel(question: discussionQuestions(in: inbox)[0])
        form.choice = "1時間"
        form.startsLoopAfterPosting = true
        form.loopRunner = .manual
        await form.post(using: inbox)

        // 信用する author の Discussion なので回答は投稿し、印は付けずに理由を出す
        #expect(form.isPosted)
        #expect(starter.markedManual.isEmpty)
        #expect(form.errorMessage == "この Discussion には、ほかに未回答の質問が 1 件あるため、ループを始めませんでした")
    }

    @Test func refusesManualLoopBeforePostingForUntrustedDiscussion() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let questions = discussionQuestions(in: inbox)
        try await inbox.post(Answer(choice: "1時間"), to: questions[0])
        // 信用する author の質問でも、Discussion を作ったのが信用外の author なら manual-loop は効かない
        var question = questions[1]
        question.subject.author = "someone"
        let form = AnswerFormModel(question: question)
        #expect(form.canStartLoop(in: inbox))
        #expect(!form.canRunManually(in: inbox))

        form.note = "朝だけにしたい"
        form.startsLoopAfterPosting = true
        form.loopRunner = .manual
        await form.post(using: inbox)

        // 回答も投稿せず、印も付けない
        #expect(!form.isPosted)
        #expect(starter.markedManual.isEmpty)
        #expect(starter.marked.isEmpty)
        #expect(form.errorMessage?.contains("信用する author が作ったものではない") == true)
    }

    @Test func doesNotMarkWithoutChoosingToStartLoop() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let form = AnswerFormModel(question: discussionQuestions(in: inbox)[0])
        form.choice = "1時間"
        form.startsLoopAfterPosting = false
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
        #expect(form.errorMessage == "この Discussion には、ほかに未回答の質問が 1 件あるため、ループを始めませんでした")
    }

    @Test func retryChecksRemainingQuestionsAgain() async throws {
        let starter = RecordingStarter()
        let inbox = await makeInbox(starter: starter)
        let form = AnswerFormModel(question: discussionQuestions(in: inbox)[0])
        // 再試行の時点でほかの未回答の質問が残っていれば、印を付けずに理由を出す
        await form.startLoop(using: inbox)

        #expect(starter.marked.isEmpty)
        #expect(!form.loopStartFailed)
        #expect(form.errorMessage?.contains("ほかに未回答の質問が 1 件ある") == true)
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
