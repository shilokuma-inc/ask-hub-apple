import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// Orchestrator のテストで使う差し替え（GitHub・取得元・ループの実行）

struct TestError: Error {}

struct FakeGitHubState {
    var results: [Result<[ReadyDiscussion], TestError>]
    var removed: [String] = []
    var removedNeedsAnswer: [String] = []
    var addedReady: [String] = []
    var addReadyFails = false
    var removeFails = false
    /// 既にある PR（キーは head ブランチ）
    var existingPullRequests: [String: ExistingPullRequest] = [:]
    var createdEpicPullRequests: [String] = []
    var labeledPullRequests: [Int] = []
    var updatedPullRequestBodies: [String] = []
    var labelFails = false
    var ideaIssues: [IdeaRequestIssue] = []
    var ideaComments: [String] = []
    var closedIdeas: [Int] = []
    var ideaCommentFails = false
    var heartbeats: [String] = []
    var heartbeatFails = false
    var ideaCloseFails = false
    var decisionLogs: [DecisionLogIssue] = []
    /// 仮決め一覧のコメント（キーは Issue の番号）
    var issueComments: [Int: [IssueComment]] = [:]
    var decisionComments: [String] = []
    var closedDecisionLogs: [Int] = []
    var decisionCloseFails = false
}

/// `needs-answer` の Discussion / PR を返す取得元。スレッドはテストから差し替える
final class FakeInbox: InboxSource {
    private let state = OSAllocatedUnfairLock<(subjects: [InboxSubject], threads: [String: [QuestionThread]])>(initialState: ([], [:]))

    func set(_ subjects: [InboxSubject], threads: [String: [QuestionThread]]) {
        state.withLock { $0 = (subjects, threads) }
    }

    func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
        state.withLock { $0.subjects }
    }

    /// スレッドを登録していない Discussion / PR は取得に失敗する
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        guard let threads = state.withLock({ $0.threads[subject.nodeID] }) else {
            throw TestError()
        }
        return threads
    }

    func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
        []
    }
}

struct FakeRuntimeState {
    var launched: [[String]] = []
    var status = LoopStatus.idle
    var launchFails = false
    var epic = EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil)
    var usageLimitReset: Date?
    var hungLoop: HungLoop?
    var terminated: [HungLoop] = []
    /// `run` が順に返す結果。尽きたら最後のものを返し続ける
    var runResults: [CommandResult] = [CommandResult(status: 0, output: "")]
    var ran: [[String]] = []
    var inputs: [String] = []
}

final class FakeGitHub: OrchestratorGitHub {
    private let state: OSAllocatedUnfairLock<FakeGitHubState>

    init(_ results: [Result<[ReadyDiscussion], TestError>]) {
        state = OSAllocatedUnfairLock(initialState: FakeGitHubState(results: results))
    }

    var removed: [String] {
        state.withLock { $0.removed }
    }

    func setRemoveFails(_ fails: Bool) {
        state.withLock { $0.removeFails = fails }
    }

    func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion] {
        try state.withLock { state in
            guard let first = state.results.first else {
                return []
            }
            if state.results.count > 1 {
                state.results.removeFirst()
            }
            return try first.get()
        }
    }

    var removedNeedsAnswer: [String] {
        state.withLock { $0.removedNeedsAnswer }
    }

    var addedReady: [String] {
        state.withLock { $0.addedReady }
    }

    func setAddReadyFails(_ fails: Bool) {
        state.withLock { $0.addReadyFails = fails }
    }

    func addReadyLabel(to subject: InboxSubject) async throws {
        try state.withLock { state in
            if state.addReadyFails {
                throw TestError()
            }
            state.addedReady.append(subject.nodeID)
        }
    }

    func removeNeedsAnswerLabel(from subject: InboxSubject) async throws {
        state.withLock { $0.removedNeedsAnswer.append(subject.nodeID) }
    }

    var createdEpicPullRequests: [String] {
        state.withLock { $0.createdEpicPullRequests }
    }

    var labeledPullRequests: [Int] {
        state.withLock { $0.labeledPullRequests }
    }

    func addExistingPullRequest(head: String, _ pull: ExistingPullRequest) {
        state.withLock { $0.existingPullRequests[head] = pull }
    }

    func setLabelFails(_ fails: Bool) {
        state.withLock { $0.labelFails = fails }
    }

    func existingPullRequest(in repository: String, head branch: String) async throws -> ExistingPullRequest? {
        state.withLock { $0.existingPullRequests[branch] }
    }

    func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int {
        state.withLock { state in
            state.createdEpicPullRequests.append("\(repository) \(branch): \(body)")
            state.existingPullRequests[branch] = ExistingPullRequest(number: 100, isOpen: true)
            return 100
        }
    }

    func setIdeaIssues(_ issues: [IdeaRequestIssue]) {
        state.withLock { $0.ideaIssues = issues }
    }

    var heartbeats: [String] {
        state.withLock { $0.heartbeats }
    }

    func setHeartbeatFails(_ fails: Bool) {
        state.withLock { $0.heartbeatFails = fails }
    }

    func updateHeartbeat(in repository: String, description: String) async throws {
        try state.withLock { state in
            if state.heartbeatFails {
                throw TestError()
            }
            state.heartbeats.append("\(repository): \(description)")
        }
    }

    func setDecisionLogs(_ issues: [DecisionLogIssue], comments: [Int: [IssueComment]] = [:]) {
        state.withLock {
            $0.decisionLogs = issues
            $0.issueComments = comments
        }
    }

    func setDecisionCloseFails(_ fails: Bool) {
        state.withLock { $0.decisionCloseFails = fails }
    }

    var decisionComments: [String] {
        state.withLock { $0.decisionComments }
    }

    var closedDecisionLogs: [Int] {
        state.withLock { $0.closedDecisionLogs }
    }

    func decisionLogs(in repository: String) async throws -> [DecisionLogIssue] {
        state.withLock { $0.decisionLogs.filter { $0.repository == repository } }
    }

    func comments(in repository: String, issue number: Int) async throws -> [IssueComment] {
        state.withLock { $0.issueComments[number] ?? [] }
    }

    /// コメントは、次の取得で返るように Issue のコメントにも足す
    func comment(on issue: DecisionLogIssue, body: String) async throws {
        state.withLock { state in
            state.decisionComments.append("#\(issue.number): \(body)")
            let id = 9_000 + state.decisionComments.count
            state.issueComments[issue.number, default: []].append(IssueComment(id: id, author: "mrs1669", body: body))
        }
    }

    func close(_ issue: DecisionLogIssue) async throws {
        try state.withLock { state in
            if state.decisionCloseFails {
                throw TestError()
            }
            state.closedDecisionLogs.append(issue.number)
        }
    }

    func setIdeaCommentFails(_ fails: Bool) {
        state.withLock { $0.ideaCommentFails = fails }
    }

    func setIdeaCloseFails(_ fails: Bool) {
        state.withLock { $0.ideaCloseFails = fails }
    }

    var ideaComments: [String] {
        state.withLock { $0.ideaComments }
    }

    var closedIdeas: [Int] {
        state.withLock { $0.closedIdeas }
    }

    func ideaRequests(org: String) async throws -> [IdeaRequestIssue] {
        state.withLock { $0.ideaIssues }
    }

    func comment(on issue: IdeaRequestIssue, body: String) async throws {
        try state.withLock { state in
            if state.ideaCommentFails {
                throw TestError()
            }
            state.ideaComments.append("#\(issue.number): \(body)")
        }
    }

    func close(_ issue: IdeaRequestIssue) async throws {
        try state.withLock { state in
            if state.ideaCloseFails {
                throw TestError()
            }
            state.closedIdeas.append(issue.number)
        }
    }

    var updatedPullRequestBodies: [String] {
        state.withLock { $0.updatedPullRequestBodies }
    }

    func updatePullRequestBody(in repository: String, number: Int, body: String) async throws {
        state.withLock { $0.updatedPullRequestBodies.append("#\(number): \(body)") }
    }

    func addEpicFinalLabel(in repository: String, number: Int) async throws {
        try state.withLock { state in
            if state.labelFails {
                throw TestError()
            }
            state.labeledPullRequests.append(number)
        }
    }

    func removeReadyLabel(from discussion: ReadyDiscussion) async throws {
        try state.withLock { state in
            if state.removeFails {
                throw TestError()
            }
            state.removed.append(discussion.nodeID)
        }
    }
}

/// 起動したコマンドを記録するだけで、実際には起動しない。ループの状態はテストから変える
final class FakeRuntime: LoopRuntime {
    private let state = OSAllocatedUnfairLock(initialState: FakeRuntimeState())

    var launched: [[String]] {
        state.withLock { $0.launched }
    }

    func set(_ status: LoopStatus) {
        state.withLock { $0.status = status }
    }

    func setLaunchFails(_ fails: Bool) {
        state.withLock { $0.launchFails = fails }
    }

    func status(of repository: RepositoryConfig) async -> LoopStatus {
        state.withLock { $0.status }
    }

    func launch(_ arguments: [String], for repository: RepositoryConfig) async throws {
        try state.withLock { state in
            if state.launchFails {
                throw TestError()
            }
            state.launched.append(arguments)
            // 起動したプロセスは、テストが状態を変えるまで生きている
            state.status = LoopStatus(stateFileExists: false, processAlive: true)
        }
    }

    func setEpic(_ epic: EpicSnapshot) {
        state.withLock { $0.epic = epic }
    }

    func setUsageLimitReset(_ date: Date?) {
        state.withLock { $0.usageLimitReset = date }
    }

    func usageLimitReset(of repository: RepositoryConfig) async -> Date? {
        state.withLock { $0.usageLimitReset }
    }

    func setHungLoop(_ loop: HungLoop?) {
        state.withLock { $0.hungLoop = loop }
    }

    var terminated: [HungLoop] {
        state.withLock { $0.terminated }
    }

    func hungLoop(of repository: RepositoryConfig, timeout: Duration, now: Date) async -> HungLoop? {
        state.withLock { $0.hungLoop }
    }

    func terminate(_ loop: HungLoop) async {
        state.withLock { state in
            state.terminated.append(loop)
            // 止めたプロセスは終わり、state ファイルだけが残る（異常終了）
            state.hungLoop = nil
            state.status = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)
        }
    }

    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot {
        state.withLock { $0.epic }
    }

    func setRunResults(_ results: [CommandResult]) {
        state.withLock { $0.runResults = results }
    }

    var ran: [[String]] {
        state.withLock { $0.ran }
    }

    var inputs: [String] {
        state.withLock { $0.inputs }
    }

    func run(_ arguments: [String], input: String, for repository: RepositoryConfig, timeout: Duration) async throws -> CommandResult {
        state.withLock { state in
            state.ran.append(arguments)
            state.inputs.append(input)
            let result = state.runResults[0]
            if state.runResults.count > 1 {
                state.runResults.removeFirst()
            }
            return result
        }
    }
}

final class LogRecorder: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

    var recorded: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}
