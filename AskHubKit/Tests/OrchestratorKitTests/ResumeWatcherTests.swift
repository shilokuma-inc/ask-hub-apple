import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct ResumeWatcherTests {
    private let key = "shilokuma-inc/ask-hub-apple"

    private func subject(_ kind: InboxSubject.Kind = .pullRequest, number: Int = 34) -> InboxSubject {
        InboxSubject(
            kind: kind,
            nodeID: "S_\(number)",
            repository: "shilokuma-inc/ask-hub-apple",
            number: number,
            title: "T",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/\(number)")!
        )
    }

    private func snapshot(_ questions: [(String, Bool)], kind: InboxSubject.Kind = .pullRequest) -> AnswerSnapshot {
        AnswerSnapshot(subject: subject(kind), questions: questions.map { AnswerSnapshot.Question(id: $0.0, isAnswered: $0.1) })
    }

    @Test func readsTrustedQuestionsAndAnswers() {
        func thread(_ id: String, author: String?, body: String, replies: [String?]) -> QuestionThread {
            QuestionThread(
                comment: InboxComment(
                    nodeID: id,
                    databaseID: nil,
                    author: author,
                    body: body,
                    url: URL(string: "https://github.com")!,
                    createdAt: Date()
                ),
                replyAuthors: replies
            )
        }
        let marker = #"<!-- ask-hub:question id="pr34-1" -->"#
        let result = AnswerSnapshot(
            subject: subject(),
            threads: [
                thread("A", author: "mrs1669", body: marker, replies: ["coderabbitai", "mrs1669"]),
                thread("B", author: "mrs1669", body: marker, replies: ["someone"]),
                thread("C", author: "someone", body: marker, replies: []),
                thread("D", author: "mrs1669", body: "目印なし", replies: [])
            ],
            trustedAuthors: TrustedAuthors(["mrs1669"])
        )
        #expect(result.questions == [.init(id: "A", isAnswered: true), .init(id: "B", isAnswered: false)])
        #expect(!result.isFullyAnswered)
        #expect(!AnswerSnapshot(subject: subject(), questions: []).isFullyAnswered)
    }

    @Test func resumesStoppedLoopOnceForNewAnswerAndConfirmsByStateFile() {
        var watcher = ResumeWatcher()
        let partial = snapshot([("A", true), ("B", false)])

        #expect(watcher.update(snapshots: [partial], statuses: [:]) == [.resume(repositoryKey: key)])
        watcher.recordLaunch(repositoryKey: key)
        // 起動中は待つ
        #expect(watcher.update(snapshots: [partial], statuses: [key: LoopStatus(stateFileExists: false, processAlive: true)]).isEmpty)
        // state ファイルが現れたら再開できた
        #expect(watcher.update(snapshots: [partial], statuses: [key: LoopStatus(stateFileExists: true, processAlive: true)]).isEmpty)
        #expect(watcher.resumes.isEmpty)
        // ループが終わっても、同じ回答では再開しない
        #expect(watcher.update(snapshots: [partial], statuses: [:]).isEmpty)

        // 新しい回答が付いたら再開する
        let full = snapshot([("A", true), ("B", true)])
        #expect(watcher.update(snapshots: [full], statuses: [:]) == [.removeNeedsAnswer(full.subject), .resume(repositoryKey: key)])
    }

    @Test func doesNotLaunchWhileLoopIsRunningOrUnknown() {
        var watcher = ResumeWatcher()
        let answered = snapshot([("A", true), ("B", false)])

        #expect(watcher.update(snapshots: [answered], statuses: [key: LoopStatus(stateFileExists: nil, processAlive: false)]).isEmpty)
        #expect(watcher.resumes[key]?.phase == .waiting)
        // 動いているループは自分で回答を拾うので、再開待ちをやめる
        #expect(watcher.update(snapshots: [answered], statuses: [key: LoopStatus(stateFileExists: true, processAlive: false)]).isEmpty)
        #expect(watcher.resumes.isEmpty)
    }

    @Test func discussionAnswersRemoveLabelWithoutResuming() {
        var watcher = ResumeWatcher()
        let discussion = snapshot([("Q1", true), ("Q2", true)], kind: .discussion)
        #expect(watcher.update(snapshots: [discussion], statuses: [:]) == [.removeNeedsAnswer(discussion.subject)])
        #expect(watcher.resumes.isEmpty)
    }

    @Test func manualLoopDiscussionRemovesOnlyNeedsAnswer() {
        var watcher = ResumeWatcher()
        let discussion = AnswerSnapshot(
            subject: subject(.discussion),
            questions: [.init(id: "Q1", isAnswered: true)],
            isManualLoop: true
        )
        #expect(watcher.update(snapshots: [discussion], statuses: [:]) == [.removeNeedsAnswerOfManualLoop(discussion.subject)])
        #expect(watcher.resumes.isEmpty)
    }

    @Test func readsManualLoopOnlyFromTrustedDiscussions() {
        func snapshot(kind: InboxSubject.Kind, author: String?, labels: [String]) -> AnswerSnapshot {
            var subject = subject(kind)
            subject.author = author
            subject.labels = labels
            return AnswerSnapshot(subject: subject, threads: [], trustedAuthors: TrustedAuthors(["mrs1669"]))
        }
        #expect(snapshot(kind: .discussion, author: "mrs1669", labels: ["needs-answer", "manual-loop"]).isManualLoop)
        #expect(!snapshot(kind: .discussion, author: "someone", labels: ["manual-loop"]).isManualLoop)
        #expect(!snapshot(kind: .discussion, author: nil, labels: ["manual-loop"]).isManualLoop)
        #expect(!snapshot(kind: .discussion, author: "mrs1669", labels: ["needs-answer"]).isManualLoop)
        // PR に付いた manual-loop は Discussion の目印ではない
        #expect(!snapshot(kind: .pullRequest, author: "mrs1669", labels: ["manual-loop"]).isManualLoop)
    }

    @Test func retriesUntilMaxAttemptsThenGivesUpUntilNextAnswer() {
        var watcher = ResumeWatcher()
        let first = snapshot([("A", true), ("B", false)])
        for _ in 0..<ResumeWatcher.maxAttempts {
            #expect(watcher.update(snapshots: [first], statuses: [:]) == [.resume(repositoryKey: key)])
            watcher.recordLaunch(repositoryKey: key)
        }
        // 3 回起動しても state ファイルが現れないまま終わった
        #expect(watcher.update(snapshots: [first], statuses: [:]) == [.giveUp(repositoryKey: key, attempts: ResumeWatcher.maxAttempts)])
        #expect(watcher.update(snapshots: [first], statuses: [:]).isEmpty)

        // 新しい回答が付いたら、もう一度試す
        let second = snapshot([("A", true), ("B", true)])
        #expect(watcher.update(snapshots: [second], statuses: [:]).contains(.resume(repositoryKey: key)))
    }

    @Test func launchFailuresCountTowardsMaxAttempts() {
        var watcher = ResumeWatcher()
        _ = watcher.update(snapshots: [snapshot([("A", true)])], statuses: [:])
        #expect(watcher.recordLaunchFailure(repositoryKey: key).phase == .waiting)
        #expect(watcher.recordLaunchFailure(repositoryKey: key).phase == .waiting)
        #expect(watcher.recordLaunchFailure(repositoryKey: key).phase == .gaveUp)
    }

    @Test func doesNotResumeWithoutEpicInProgress() {
        var watcher = ResumeWatcher()
        // epic とは関係のない PR の ask に回答が付いても、途中の epic が無ければ起動スクリプトも断るので再開しない
        let full = snapshot([("A", true)])
        #expect(
            watcher.update(snapshots: [full], statuses: [:], epicsInProgress: [])
                == [.removeNeedsAnswer(full.subject), .noEpicInProgress(repositoryKey: key)]
        )
        #expect(watcher.resumes.isEmpty)
        // 同じ回答では知らせ直さない
        #expect(watcher.update(snapshots: [full], statuses: [:], epicsInProgress: []) == [.removeNeedsAnswer(full.subject)])
    }

    @Test func forgetsGaveUpOnceEpicIsNoLongerInProgress() {
        var watcher = ResumeWatcher()
        let partial = snapshot([("A", true), ("B", false)])
        for _ in 0..<ResumeWatcher.maxAttempts {
            _ = watcher.update(snapshots: [partial], statuses: [:])
            watcher.recordLaunch(repositoryKey: key)
        }
        #expect(watcher.update(snapshots: [partial], statuses: [:]) == [.giveUp(repositoryKey: key, attempts: ResumeWatcher.maxAttempts)])
        #expect(watcher.resumes[key]?.phase == .gaveUp)

        // epic が終われば（残りが回答待ちだけ・マージして片付いた）、諦めた記録を残さない（ループの状態が「異常終了」のまま残らない）
        #expect(watcher.update(snapshots: [partial], statuses: [:], epicsInProgress: []).isEmpty)
        #expect(watcher.resumes.isEmpty)
    }
}

// MARK: - 同じリポジトリの自動ループと手動ループ（PR の base で振り分ける）

extension ResumeWatcherTests {
    /// 新しく回答が付いた PR。ほかの質問は未回答のまま（再開だけを確かめるため、needs-answer は外れない）
    private func answered(_ id: String, base: String?, number: Int) -> AnswerSnapshot {
        var subject = subject(.pullRequest, number: number)
        subject.baseBranch = base
        return AnswerSnapshot(subject: subject, questions: [.init(id: id, isAnswered: true), .init(id: id + "-2", isAnswered: false)])
    }

    private var automatic: [String: String] {
        [key: "epic/auto"]
    }

    @Test func resumesOnlyForAnswersOnPullRequestsToAutomaticEpic() {
        // 手動ループがあっても、自動ループの epic 宛ての PR の回答では再開する
        var watcher = ResumeWatcher()
        let toAutomatic = watcher.update(
            snapshots: [answered("A", base: "epic/auto", number: 34)],
            statuses: [:],
            epicsInProgress: [key],
            automaticEpics: automatic,
            manualLoopRepositories: [key]
        )
        #expect(toAutomatic == [.resume(repositoryKey: key)])

        // 手動ループの epic 宛ての PR の回答では再開しない（担当者が再開する）
        var manual = ResumeWatcher()
        let toManual = manual.update(
            snapshots: [answered("B", base: "epic/manual", number: 35)],
            statuses: [:],
            epicsInProgress: [key],
            automaticEpics: automatic,
            manualLoopRepositories: [key]
        )
        #expect(toManual.isEmpty)
        #expect(manual.resumes.isEmpty)

        // 手動ループが無くても、自動ループの epic 以外（develop など）宛ての PR の回答では再開しない
        var other = ResumeWatcher()
        let toDevelop = other.update(
            snapshots: [answered("C", base: "develop", number: 36)], statuses: [:], epicsInProgress: [key], automaticEpics: automatic
        )
        #expect(toDevelop.isEmpty)
    }

    @Test func treatsPullRequestWithoutBaseAsBeforeOnlyWithoutManualLoop() {
        var watcher = ResumeWatcher()
        let withoutManualLoop = watcher.update(
            snapshots: [answered("A", base: nil, number: 34)], statuses: [:], epicsInProgress: [key], automaticEpics: automatic
        )
        #expect(withoutManualLoop == [.resume(repositoryKey: key)])

        // 手動ループのあるリポジトリでは、どのループの PR か分からないので再開しない
        var manual = ResumeWatcher()
        let withManualLoop = manual.update(
            snapshots: [answered("B", base: nil, number: 35)],
            statuses: [:],
            epicsInProgress: [key],
            automaticEpics: automatic,
            manualLoopRepositories: [key]
        )
        #expect(withManualLoop.isEmpty)
    }

    @Test func keepsWaitingResumeOfAutomaticEpicWhileManualLoopRuns() {
        var watcher = ResumeWatcher()
        // 制御用 worktree の状態を確かめられない間は、再開待ちのまま残る
        let unknown = [key: LoopStatus(stateFileExists: nil, processAlive: false)]
        #expect(watcher.update(
            snapshots: [answered("A", base: "epic/auto", number: 34)], statuses: unknown, epicsInProgress: [key], automaticEpics: automatic
        ).isEmpty)
        #expect(watcher.resumes[key]?.phase == .waiting)

        // 同じリポジトリで手動ループが始まっても、自動ループの再開待ちは消さない
        let resumed = watcher.update(
            snapshots: [], statuses: [:], epicsInProgress: [key], automaticEpics: automatic, manualLoopRepositories: [key]
        )
        #expect(resumed == [.resume(repositoryKey: key)])

        // 制御用 worktree を手動ループが使っている（自動ループの epic が無い）なら、再開待ちをやめる
        var occupied = ResumeWatcher()
        _ = occupied.update(
            snapshots: [answered("B", base: "epic/auto", number: 35)], statuses: unknown, epicsInProgress: [key], automaticEpics: automatic
        )
        _ = occupied.update(snapshots: [], statuses: [:], epicsInProgress: [key], manualLoopRepositories: [key])
        #expect(occupied.resumes.isEmpty)
    }
}

private extension ResumeWatcher {
    /// 途中の epic がある（回答で再開できる）リポジトリとして進める。途中の epic が無いときは `epicsInProgress` を渡して確かめる
    mutating func update(snapshots: [AnswerSnapshot], statuses: [String: LoopStatus]) -> [Action] {
        update(snapshots: snapshots, statuses: statuses, epicsInProgress: ["shilokuma-inc/ask-hub-apple"])
    }
}
