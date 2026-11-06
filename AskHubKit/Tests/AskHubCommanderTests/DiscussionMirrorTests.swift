@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// ログの行を残す
final class LogLines: Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    var lines: [String] { state.withLock { $0 } }

    func append(_ line: String) {
        state.withLock { $0.append(line) }
    }
}

/// 状態リポジトリの中身を Discussion に写す
extension ClaudeJobRunnerTests {
    var verifier: IntentVerifier { IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]) }

    func mirror(
        _ store: InMemoryStateStore,
        github: FakeDiscussions,
        clock: TestClock = TestClock(ClaudeJobRunnerTests.now),
        logs: LogLines = LogLines()
    ) -> DiscussionMirror {
        DiscussionMirror(context: CommanderContext(store: store, mac: Self.commander) { clock.now }, api: github) { logs.append($0) }
    }

    /// 質問の一覧を置いた epic（`answers` を受け付けた後）
    func asking(_ answers: (EpicFile) -> [AnswerIntent] = { _ in [] }) async throws -> (store: InMemoryStateStore, epic: EpicFile) {
        let given = try await requested()
        let drafts = [QuestionJobsTests.draft("q1"), QuestionJobsTests.draft("q2"), QuestionJobsTests.draft("q3", dependsOn: ["q1"])]
        _ = try await answered(answers(given.epic), drafts: drafts, in: given.store, epic: given.epic)
        return (given.store, given.epic)
    }

    func discussionNumber(of epic: EpicFile, in store: InMemoryStateStore) async throws -> Int {
        try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.discussion)
    }

    @Test func comparesCopiesIgnoringLineEndings() {
        let copy = DiscussionCopiesTests.copies().request
        #expect(DiscussionMirror.same(copy.text.replacingOccurrences(of: "\n", with: "\r\n"), copy.text))
        #expect(!DiscussionMirror.same("目印なし", copy.text))
    }

    @Test func loopMirrorsRequestSummaryAndGoal() async throws {
        let store = try await storeWithRequest()
        let github = FakeDiscussions { Self.now }
        let claude = ScriptedRunner([
            QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#),
            Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))
        ])
        let loop = loop(store, claude: claude, mirror: mirror(store, github: github))
        // 1 周目の最後に Discussion を作り、番号を epic に戻す
        _ = try await loop.cycle()
        await loop.waitForJobs()
        let epic = try #require(try await epics(in: store).first)
        let discussion = try #require(github.discussions.first)
        #expect(epic.discussion == discussion.number)
        #expect(discussion.title == "ランキング 0")
        #expect(discussion.body.contains("> 日ごとに入れ替えたい"))
        // 2 周目・3 周目: 要約・着手前の確認の結果・ゴールを写し、ゴールの写しの id を戻す
        _ = try await loop.cycle()
        await loop.waitForJobs()
        _ = try await loop.cycle()
        let body = try #require(github.discussions.first?.body)
        #expect(body.contains("文言を直す。"))
        #expect(body.contains("ゴールの確認と開始を待っています"))
        #expect(body.contains("- 結果: 進めてよい"))
        let goal = try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store))
        let texts = github.texts(of: discussion.number)
        #expect(texts.count == 1)
        #expect(texts.first?.contains("## ゴール（版 1）") == true)
        #expect(goal.comment == github.discussions.first?.comments.first?.post.id)
        #expect(github.discussions.count == 1)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func mirrorsQuestionsWithAnswersAndExplanations() async throws {
        let (store, epic) = try await asking { epic in
            [
                self.answer("q1", note: "夜間は長めに", epic: epic, nonce: 1),
                self.answer("q2", mode: .clarify, note: "保存とは？", epic: epic, nonce: 2)
            ]
        }
        let github = FakeDiscussions { Self.now }
        let mirror = mirror(store, github: github)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        let path = StatePath.questions(Self.repo, epic.id)
        let questions = try #require(try await read(QuestionsFile.self, at: path, in: store))
        #expect(questions.questions.allSatisfy { $0.comment != nil })
        // q1・その回答の写し・q2・その説明（作っている途中）・q3 の順
        let texts = github.texts(of: number)
        #expect(texts.count == 5)
        #expect(texts[0].contains("### q1. q1 の題") && texts[0].contains("回答済み（案1）"))
        #expect(texts[1].contains("**回答**: 案1") && texts[1].contains("> 夜間は長めに"))
        #expect(ProtocolMarker.parse(texts[1])?.value["type"] == .string("copy"))
        #expect(texts[3].contains("> 保存とは？") && texts[3].contains("（説明を作っています）"))
        #expect(texts[4].contains("見直しています") && texts[4].contains("q1 の回答を前提にしています"))
        // 説明が書かれたら、同じ返信を直す（新しく足さない）
        var explained = questions
        explained.questions[1].explanations[0].text = "端末に残すことです。"
        explained.questions[1].state = .open
        try await put(explained, at: path, in: store)
        let added = github.calls.filter { $0 == "addComment" }.count
        await mirror.syncAll(verifier: verifier)
        #expect(github.texts(of: number)[3].contains("端末に残すことです。"))
        #expect(github.calls.filter { $0 == "addComment" }.count == added)
        // 変わっていなければ、GitHub を読まない
        let calls = github.calls.count
        await mirror.syncAll(verifier: verifier)
        #expect(github.calls.count == calls)
    }

    @Test func findsCopiesWrittenBeforeStopping() async throws {
        let (store, epic) = try await asking { [self.answer("q1", epic: $0, nonce: 1)] }
        let github = FakeDiscussions { Self.now }
        await mirror(store, github: github).syncAll(verifier: verifier)
        let writes = github.writes
        // 写しを作った後、id を状態に戻す前に止まった様子にする
        let epicPath = StatePath.epic(Self.repo, epic.id)
        var stopped = try #require(try await read(EpicFile.self, at: epicPath, in: store))
        let number = stopped.discussion
        stopped.discussion = nil
        try await put(stopped, at: epicPath, in: store)
        let path = StatePath.questions(Self.repo, epic.id)
        var questions = try #require(try await read(QuestionsFile.self, at: path, in: store))
        let comments = questions.questions.map(\.comment)
        questions = questions.withoutCopies
        try await put(questions, at: path, in: store)
        // 起動し直した司令塔（前に写したことを覚えていない）は、目印で見つけて id を戻し、作り直さない
        await mirror(store, github: github).syncAll(verifier: verifier)
        #expect(github.writes == writes)
        #expect(github.discussions.count == 1)
        #expect(try await read(EpicFile.self, at: epicPath, in: store)?.discussion == number)
        #expect(try await read(QuestionsFile.self, at: path, in: store)?.questions.map(\.comment) == comments)
    }

    @Test func ignoresDiscussionsWrittenByOthers() async throws {
        let given = try await requested()
        let github = FakeDiscussions { Self.now }
        // public のリポジトリで、誰かが目印をまねた Discussion を先に作った
        let marker = DiscussionCopies.marker("request", epic: given.epic.id)
        let body = ProtocolMarker.text(body: "偽", marker: marker)
        let fake = FakeDiscussions.Stored(id: "D_fake", number: 1, title: "偽", body: body, viewerDidAuthor: false, createdAt: Self.now)
        github.change { $0.discussions.append(fake) }
        await mirror(given.store, github: github).syncAll(verifier: verifier)
        #expect(try await discussionNumber(of: given.epic, in: given.store) == 2)
        #expect(github.discussions.first?.body == fake.body)
    }

    @Test func waitsWhileDiscussionsAreDisabled() async throws {
        let given = try await requested()
        let clock = TestClock(Self.now)
        let github = FakeDiscussions { clock.now }
        github.change { $0.repository.discussionsEnabled = false }
        let logs = LogLines()
        let mirror = mirror(given.store, github: github, clock: clock, logs: logs)
        await mirror.syncAll(verifier: verifier)
        #expect(github.discussions.isEmpty)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, given.epic.id), in: given.store)?.discussion == nil)
        #expect(logs.lines.contains { $0.contains("Discussions が無効") })
        // 人が直すまで、すぐにはやり直さない
        let calls = github.calls.count
        await mirror.syncAll(verifier: verifier)
        #expect(github.calls.count == calls)
        // 有効にされ、間を空けた後の周で作る
        github.change { $0.repository.discussionsEnabled = true }
        clock.advance(minutes: 60)
        await mirror.syncAll(verifier: verifier)
        #expect(github.discussions.count == 1)
    }

    @Test func doesNotRecreateDeletedCopies() async throws {
        let (store, epic) = try await asking()
        let github = FakeDiscussions { Self.now }
        let mirror = mirror(store, github: github)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        let path = StatePath.questions(Self.repo, epic.id)
        var questions = try #require(try await read(QuestionsFile.self, at: path, in: store))
        let deleted = try #require(questions.questions[0].comment)
        github.delete(deleted)
        // 人が q2 に答えた
        questions.questions[1].state = .answered
        questions.questions[1].answer = .init(choice: "案2", intent: answer("q2", epic: epic, nonce: 3).intent, at: Timestamp(Self.now))
        try await put(questions, at: path, in: store)
        await mirror.syncAll(verifier: verifier)
        let texts = github.texts(of: number)
        #expect(!texts.contains { $0.contains("### q1.") })
        #expect(texts.contains { $0.contains("回答済み（案2）") })
        #expect(texts.contains { $0.contains("**回答**: 案2") })
        #expect(try await read(QuestionsFile.self, at: path, in: store)?.questions[0].comment == deleted)
    }

    @Test func createsNothingWhileCommentListIsIncomplete() async throws {
        let (store, epic) = try await asking()
        let clock = TestClock(Self.now)
        let github = FakeDiscussions { clock.now }
        let mirror = mirror(store, github: github, clock: clock)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        // GitHub の障害で、コメントの一覧が空で返る
        github.change { $0.hidesComments = true }
        let path = StatePath.questions(Self.repo, epic.id)
        var questions = try #require(try await read(QuestionsFile.self, at: path, in: store))
        questions.questions[1].state = .answered
        questions.questions[1].answer = .init(choice: "案1", intent: answer("q2", epic: epic, nonce: 3).intent, at: Timestamp(Self.now))
        try await put(questions, at: path, in: store)
        let writes = github.writes
        await mirror.syncAll(verifier: verifier)
        #expect(github.writes == writes)
        // 一覧が戻れば、間を空けた後の周で写す（重ならない）
        github.change { $0.hidesComments = false }
        clock.advance(minutes: 2)
        await mirror.syncAll(verifier: verifier)
        let texts = github.texts(of: number)
        #expect(texts.filter { $0.contains("### q2.") }.count == 1)
        #expect(texts.contains { $0.contains("**回答**: 案1") })
    }

    @Test func keepsCreatedIDsWhenLaterCopyFails() async throws {
        let (store, epic) = try await asking()
        let clock = TestClock(Self.now)
        let github = FakeDiscussions { clock.now }
        let mirror = mirror(store, github: github, clock: clock)
        // q1 の写しを作った後、q2 で GitHub が落ちた
        let failing = FailingAfter(inner: github, failAt: 2)
        let partial = DiscussionMirror(context: CommanderContext(store: store, mac: Self.commander) { clock.now }, api: failing) { _ in }
        await partial.syncAll(verifier: verifier)
        let path = StatePath.questions(Self.repo, epic.id)
        let first = try #require(try await read(QuestionsFile.self, at: path, in: store))
        #expect(first.questions.map { $0.comment != nil } == [true, false, false])
        // 後の周で、続きから写す
        clock.advance(minutes: 2)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        #expect(github.texts(of: number).filter { $0.contains("### q1.") }.count == 1)
        #expect(try await read(QuestionsFile.self, at: path, in: store)?.questions.allSatisfy { $0.comment != nil } == true)
    }
}

/// `failAt` 回目のコメントの追加から、GitHub の障害で失敗させる
struct FailingAfter: DiscussionAPI {
    let inner: FakeDiscussions
    let failAt: Int

    func repository(_ repo: RepositoryFullName) async throws(DiscussionError) -> DiscussionRepository {
        try await inner.repository(repo)
    }

    func discussion(_ repo: RepositoryFullName, number: Int) async throws(DiscussionError) -> DiscussionThread? {
        try await inner.discussion(repo, number: number)
    }

    func discussions(_ repo: RepositoryFullName, createdSince since: Date) async throws(DiscussionError) -> [DiscussionSummary] {
        try await inner.discussions(repo, createdSince: since)
    }

    func missing(_ ids: [String]) async throws(DiscussionError) -> Set<String> {
        try await inner.missing(ids)
    }

    func createDiscussion(
        repository: String,
        category: String,
        title: String,
        body: String
    ) async throws(DiscussionError) -> DiscussionSummary {
        try await inner.createDiscussion(repository: repository, category: category, title: title, body: body)
    }

    func updateDiscussion(_ id: String, title: String, body: String) async throws(DiscussionError) {
        try await inner.updateDiscussion(id, title: title, body: body)
    }

    func addComment(to discussion: String, replyingTo parent: String?, body: String) async throws(DiscussionError) -> String {
        if inner.calls.filter({ $0 == "addComment" }).count + 1 >= failAt { throw .http(.serverError(status: 502)) }
        return try await inner.addComment(to: discussion, replyingTo: parent, body: body)
    }

    func updateComment(_ id: String, body: String) async throws(DiscussionError) {
        try await inner.updateComment(id, body: body)
    }
}
