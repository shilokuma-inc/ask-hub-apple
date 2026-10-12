import Foundation
@testable import OrchestratorKit
import os

// FakeGitHub の、状態用の Issue（loop-status）まわり
extension FakeGitHub {
    var loopStatusIssuesByNumber: [Int: LoopStatusIssueRecord] {
        state.withLock { $0.loopStatusIssues }
    }

    var createdLoopStatusIssues: [String] {
        state.withLock { $0.createdLoopStatusIssues }
    }

    var updatedLoopStatusIssues: [String] {
        state.withLock { $0.updatedLoopStatusIssues }
    }

    var loopStatusIssueListings: Int {
        state.withLock { $0.loopStatusIssueListings }
    }

    func setLoopStatusIssues(_ issues: [LoopStatusIssueRecord]) {
        state.withLock { $0.loopStatusIssues = Dictionary(uniqueKeysWithValues: issues.map { ($0.number, $0) }) }
    }

    func setLoopStatusFails(_ fails: Bool) {
        state.withLock { $0.loopStatusFails = fails }
    }

    func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        try state.withLock { state in
            if state.loopStatusFails {
                throw TestError()
            }
            state.loopStatusIssueListings += 1
            return state.loopStatusIssues.values.sorted { $0.number < $1.number }
        }
    }

    func createLoopStatusIssue(in repository: String, body: String) async throws -> Int {
        try state.withLock { state in
            if state.loopStatusFails {
                throw TestError()
            }
            let number = (state.loopStatusIssues.keys.max() ?? 100) + 1
            state.loopStatusIssues[number] = LoopStatusIssueRecord(
                number: number, author: "mrs1669", isOpen: true, updatedAt: Date(timeIntervalSince1970: 0), body: body
            )
            state.createdLoopStatusIssues.append("\(repository)#\(number)")
            return number
        }
    }

    func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws {
        try state.withLock { state in
            guard !state.loopStatusFails, let issue = state.loopStatusIssues[number] else {
                throw TestError()
            }
            state.loopStatusIssues[number] = LoopStatusIssueRecord(
                number: number, author: issue.author, isOpen: true, updatedAt: issue.updatedAt, body: body
            )
            state.updatedLoopStatusIssues.append("\(repository)#\(number)")
        }
    }
}
