import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// Orchestrator のテストで使う差し替え（GitHub・取得元・ループの実行）

struct TestError: Error {}

struct FakeGitHubState {
    var results: [Result<[ReadyDiscussion], TestError>]
    /// `ready-for-loop` の検索に渡された organization（呼ばれた順）
    var searchedOrgs: [[String]] = []
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
    var discussions = FakeDiscussionSettingsState() // 依頼先の Discussions の設定（OrchestratorTestDoubles+IdeaDiscussions.swift）
    /// 添付の中身（キーは blob SHA）。無い SHA は 404 として扱う
    var attachmentContents: [String: Data] = [:]
    /// 中身を取った添付の名前（呼ばれた順）
    var fetchedAttachments: [String] = []
    /// Discussion の本文に足した添付（`#<番号>: <名前>,<名前>`）
    var appendedAttachments: [String] = []
    var appendAttachmentsFails = false
    var heartbeats: [String] = []
    var discussionComments: [String] = []
    var conflictingPullRequests: [ConflictingPullRequest] = []
    var finalReviewCandidates: [FinalReviewCandidate] = []
    var createdComments: [String] = []
    var updatedComments: [String] = []
    var commentUpdateFailures: [Int: (status: Int, message: String?)] = [:]
    var pullRequestComments: [String] = []
    var pullRequestCommentFails = false
    /// epic のブランチごとの、最終 PR の材料
    var epicMaterials: [String: EpicMaterials] = [:]
    var heartbeatFails = false
    /// ほかのリポジトリの担当の印の最終確認の時刻（キーは owner/repo）。担当に入れる依頼で読む
    var heartbeatLastSeen: [String: Date] = [:]
    var heartbeatReadFails = false
    var ideaCloseFails = false
    var decisionLogs: [DecisionLogIssue] = []
    var epicFinalPullRequests: [EpicFinalPullRequest] = []
    var epicFinalListings = 0
    /// 仮決め一覧のコメント（キーは Issue の番号）
    var issueComments: [Int: [IssueComment]] = [:]
    var decisionComments: [String] = []
    var closedDecisionLogs: [Int] = []
    var decisionCloseFails = false
    /// 状態用の Issue（loop-status）とそのコメント（`OrchestratorTestDoubles+LoopStatus.swift`）
    var loopStatus = FakeLoopStatusState()
    /// `manual-loop` の Discussion
    var manualLoops: [ManualLoopDiscussion] = []
    var manualLoopsFail = false
    /// `repo-request` の Issue
    var repositoryRequests: [RepositoryRequestIssue] = []
    var deletedHeartbeats: [String] = []
    var closedLoopStatusIssues: [String] = []
    /// ビルドの Mac の状態の Issue（キーは番号）
    var buildHostsIssues: [Int: LoopStatusIssueRecord] = [:]
    var createdBuildHostsIssues: [String] = []
    var updatedBuildHostsIssues: [String] = []
    var buildHostsFails = false
}

final class FakeGitHub: OrchestratorGitHub {
    let state: OSAllocatedUnfairLock<FakeGitHubState>
    /// 添付の片付け（`OrchestratorTestDoubles+AttachmentCleanup.swift`）
    let cleanup = OSAllocatedUnfairLock(initialState: FakeAttachmentCleanupState())

    init(_ results: [Result<[ReadyDiscussion], TestError>]) {
        state = OSAllocatedUnfairLock(initialState: FakeGitHubState(results: results))
    }

    var removed: [String] {
        state.withLock { $0.removed }
    }

    func setRemoveFails(_ fails: Bool) {
        state.withLock { $0.removeFails = fails }
    }

    var searchedOrgs: [[String]] {
        state.withLock { $0.searchedOrgs }
    }

    /// 渡された organization の外のリポジトリの Discussion は返さない（GitHub の検索と同じく）
    func readyForLoopDiscussions(orgs: [String]) async throws -> [ReadyDiscussion] {
        try state.withLock { state in
            state.searchedOrgs.append(orgs)
            guard let first = state.results.first else {
                return []
            }
            if state.results.count > 1 {
                state.results.removeFirst()
            }
            return try first.get().filter { Self.isInside(orgs, $0.repository) }
        }
    }

    static func isInside(_ orgs: [String], _ repository: String) -> Bool {
        orgs.contains { repository.lowercased().hasPrefix($0.lowercased() + "/") }
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

    /// 最終 PR と、そのコメント（キーは PR の番号。仮決め一覧のコメントと同じ所に入れる）
    func setEpicFinalPullRequests(_ pullRequests: [EpicFinalPullRequest], comments: [Int: [IssueComment]] = [:]) {
        state.withLock {
            $0.epicFinalPullRequests = pullRequests
            $0.issueComments.merge(comments) { _, new in new }
        }
    }

    func epicFinalPullRequests(in repository: String) async throws -> [EpicFinalPullRequest] {
        state.withLock { state in
            state.epicFinalListings += 1
            return state.epicFinalPullRequests.filter { $0.repository == repository }
        }
    }

    var epicFinalListings: Int {
        state.withLock { $0.epicFinalListings }
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

    func ideaRequests(orgs: [String]) async throws -> [IdeaRequestIssue] {
        state.withLock { $0.ideaIssues }.filter { Self.isInside(orgs, $0.repository) }
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

final class LogRecorder: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

    var recorded: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}
