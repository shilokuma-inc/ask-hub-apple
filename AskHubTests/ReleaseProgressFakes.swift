@testable import AskHub
import AskHubKit
import Foundation
import os

// ReleaseProgressTests（と ReleaseNotesEditingTests の extension）で使う、リリースのワークフローと読み取りの差し替え

/// `FakeWorkflow` の中身
struct FakeWorkflowState {
    var availability = WorkflowAvailability.active
    var runs: [WorkflowRun] = []
    /// 起動の直前の読み直しでだけ返す run（最後に読んだ状態より後に始まった run）
    var runsAfterRead: [WorkflowRun]?
    var failure: WorkflowError?
    /// 読み取り（有無・run）の失敗
    var readFailure: WorkflowError?
    var dispatched: [String] = []
    var dispatchedInputs: [[String: String]] = []
    var recentRunsCalls = 0
}

/// 1 つのワークフロー。有無・run・起動の失敗を差し替えられ、起動を記録する
nonisolated final class FakeWorkflow: WorkflowProviding {
    let file: String
    private let state = OSAllocatedUnfairLock(initialState: FakeWorkflowState())

    init(file: String) {
        self.file = file
    }

    var dispatched: [String] {
        state.withLock { $0.dispatched }
    }

    var dispatchedInputs: [[String: String]] {
        state.withLock { $0.dispatchedInputs }
    }

    func update(_ change: @Sendable (inout FakeWorkflowState) -> Void) {
        state.withLock { change(&$0) }
    }

    func availability(repository: String) async throws -> WorkflowAvailability {
        try state.withLock { state in
            if let readFailure = state.readFailure {
                throw readFailure
            }
            return state.availability
        }
    }

    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        try state.withLock { state in
            if let readFailure = state.readFailure {
                throw readFailure
            }
            guard state.availability != .notFound else {
                return .unsupported
            }
            return state.runs.first { $0.branch == branch }.map(LatestWorkflowRun.run) ?? .noRuns
        }
    }

    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
        state.withLock { state in
            state.recentRunsCalls += 1
            if let runsAfterRead = state.runsAfterRead {
                // 一度だけ返す（次の読み取りからは runs に入れたものを返す）
                state.runsAfterRead = nil
                state.runs = runsAfterRead
            }
            return state.runs.filter { branch == nil || $0.branch == branch }
        }
    }

    func dispatch(repository: String, ref: String, inputs: [String: String]) async throws {
        try state.withLock { state in
            if let failure = state.failure {
                throw failure
            }
            state.dispatched.append("\(repository) \(ref)")
            state.dispatchedInputs.append(inputs)
        }
    }
}

/// release/1.1.0（タグなし）があるリポジトリ。最新情報の状態と、読み取りの失敗を差し替えられる
nonisolated final class FakeReader: ReleaseReading {
    private let status = OSAllocatedUnfairLock<ReleaseNotes.Status?>(initialState: nil)
    private let whatsNew = OSAllocatedUnfairLock<[String: ConfirmedWhatsNew]>(initialState: [:])
    /// release ブランチとタグの読み取り（＝リリースの状態の読み取り全体）の失敗
    private let refsFailure = OSAllocatedUnfairLock<ReleaseReadError?>(initialState: nil)
    /// 最新情報の読み取りだけの失敗
    private let notesFailure = OSAllocatedUnfairLock<ReleaseReadError?>(initialState: nil)

    func set(status: ReleaseNotes.Status, whatsNew: [String: ConfirmedWhatsNew] = [:]) {
        self.status.withLock { $0 = status }
        self.whatsNew.withLock { $0 = whatsNew }
    }

    func fail(refs: ReleaseReadError? = nil, notes: ReleaseReadError? = nil) {
        refsFailure.withLock { $0 = refs }
        notesFailure.withLock { $0 = notes }
    }

    func refs(repository: String) async throws -> ReleaseRefs {
        if let failure = refsFailure.withLock({ $0 }) {
            throw failure
        }
        let branch = "release/1.1.0"
        let tag = "v1.0.0"
        return ReleaseRefs(
            branches: [ReleaseRef(name: branch, sha: "1", version: ReleaseVersion(branch: branch))],
            tags: [ReleaseRef(name: tag, sha: "0", version: ReleaseVersion(tag: tag))]
        )
    }

    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
        MarketingVersion(raw: "1.0.0")
    }

    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        nil
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        if let failure = notesFailure.withLock({ $0 }) {
            throw failure
        }
        let status = status.withLock { $0 } ?? .draft(ReleaseProgressTests.draft(text: "・通知を直しました"))
        return ReleaseNotes(version: version, status: status, languages: ["ja"], whatsNew: whatsNew.withLock { $0 })
    }
}
