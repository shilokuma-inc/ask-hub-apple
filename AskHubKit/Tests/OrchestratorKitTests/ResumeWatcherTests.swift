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
}
