import AskHubKit
import os

/// `needs-answer` の Discussion / PR を返す取得元。スレッドはテストから差し替える
final class FakeInbox: InboxSource {
    private let state = OSAllocatedUnfairLock<(subjects: [InboxSubject], threads: [String: [QuestionThread]])>(initialState: ([], [:]))

    func set(_ subjects: [InboxSubject], threads: [String: [QuestionThread]]) {
        state.withLock { $0 = (subjects, threads) }
    }

    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        state.withLock { $0.subjects }
    }

    /// スレッドを登録していない Discussion / PR は取得に失敗する
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        guard let threads = state.withLock({ $0.threads[subject.nodeID] }) else {
            throw TestError()
        }
        return threads
    }

    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        []
    }
}
