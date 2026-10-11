import Foundation
@testable import OrchestratorKit
import os

// FakeGitHub の、ビルドの Mac の状態の Issue（build-hosts）まわり
extension FakeGitHub {
    var buildHostsIssuesByNumber: [Int: LoopStatusIssueRecord] {
        state.withLock { $0.buildHostsIssues }
    }

    var createdBuildHostsIssues: [String] {
        state.withLock { $0.createdBuildHostsIssues }
    }

    var updatedBuildHostsIssues: [String] {
        state.withLock { $0.updatedBuildHostsIssues }
    }

    func setBuildHostsIssues(_ issues: [LoopStatusIssueRecord]) {
        state.withLock { $0.buildHostsIssues = Dictionary(uniqueKeysWithValues: issues.map { ($0.number, $0) }) }
    }

    func buildHostsIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        state.withLock { $0.buildHostsIssues.values.sorted { $0.number < $1.number } }
    }

    func createBuildHostsIssue(in repository: String, body: String) async throws -> Int {
        state.withLock { state in
            let number = (state.buildHostsIssues.keys.max() ?? 200) + 1
            state.buildHostsIssues[number] = LoopStatusIssueRecord(
                number: number, author: "mrs1669", isOpen: true, updatedAt: Date(timeIntervalSince1970: 0), body: body
            )
            state.createdBuildHostsIssues.append("\(repository)#\(number)")
            return number
        }
    }

    func updateBuildHostsIssue(in repository: String, number: Int, body: String) async throws {
        try state.withLock { state in
            guard let issue = state.buildHostsIssues[number] else {
                throw TestError()
            }
            state.buildHostsIssues[number] = LoopStatusIssueRecord(
                number: number, author: issue.author, isOpen: true, updatedAt: issue.updatedAt, body: body
            )
            state.updatedBuildHostsIssues.append("\(repository)#\(number)")
        }
    }
}

/// `xcb status --json` の代わり。呼ばれた回数を数え、`statuses` を順に返す（尽きたら失敗）
final class FakeXcbStatus: XcbStatusFetching {
    private let state: OSAllocatedUnfairLock<(calls: Int, statuses: [XcbStatus])>

    init(_ statuses: [XcbStatus]) {
        state = OSAllocatedUnfairLock(initialState: (0, statuses))
    }

    var calls: Int {
        state.withLock { $0.calls }
    }

    func status(xcbPath: String) async throws -> XcbStatus {
        try state.withLock { state in
            state.calls += 1
            guard !state.statuses.isEmpty else {
                throw XcbStatusError.failed(status: 1)
            }
            return state.statuses.removeFirst()
        }
    }
}
