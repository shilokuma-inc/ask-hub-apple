import AskHubKit
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

    var loopStatusCommentsByIssue: [Int: [LoopStatusComment]] {
        state.withLock { $0.loopStatusComments }
    }

    /// 作ったコメント（`<repo>#<Issue の番号>`）
    var createdLoopStatusComments: [String] {
        state.withLock { $0.createdLoopStatusComments }
    }

    /// 書き換えたコメント（`<repo> <コメントの id>`）
    var updatedLoopStatusComments: [String] {
        state.withLock { $0.updatedLoopStatusComments }
    }

    func setLoopStatusComments(_ comments: [LoopStatusComment], onIssue number: Int) {
        state.withLock { $0.loopStatusComments[number] = comments }
    }

    func loopStatusComments(in repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        try state.withLock { state in
            if state.loopStatusFails {
                throw TestError()
            }
            return state.loopStatusComments[number] ?? []
        }
    }

    func createLoopStatusComment(in repository: String, issue number: Int, body: String) async throws -> Int {
        try state.withLock { state in
            guard !state.loopStatusFails, state.loopStatusIssues[number] != nil else {
                throw TestError()
            }
            // GitHub と同じく、id はリポジトリの Issue をまたいで一意
            let id = (state.loopStatusComments.values.joined().map(\.id).max() ?? 1_000) + 1
            state.loopStatusComments[number, default: []].append(
                LoopStatusComment(id: id, author: "mrs1669", updatedAt: Date(timeIntervalSince1970: 0), body: body)
            )
            state.createdLoopStatusComments.append("\(repository)#\(number)")
            return id
        }
    }

    func updateLoopStatusComment(in repository: String, id: Int, body: String) async throws {
        try state.withLock { state in
            guard !state.loopStatusFails,
                  let number = state.loopStatusComments.first(where: { $0.value.contains { $0.id == id } })?.key,
                  let index = state.loopStatusComments[number]?.firstIndex(where: { $0.id == id }) else {
                throw TestError()
            }
            state.loopStatusComments[number]?[index].body = body
            state.updatedLoopStatusComments.append("\(repository) \(id)")
        }
    }
}
