import AskHubKit
import Foundation
@testable import OrchestratorKit
import os

/// FakeGitHub の、状態用の Issue（loop-status）とそのコメントの状態
struct FakeLoopStatusState {
    /// 状態用の Issue（キーは番号）
    var issues: [Int: LoopStatusIssueRecord] = [:]
    var createdIssues: [String] = []
    var updatedIssues: [String] = []
    var issueListings = 0
    /// 番号で読んだ状態用の Issue（`<repo>#<番号>`）
    var readIssues: [String] = []
    var fails = false
    /// 状態用の Issue のコメント（キーは Issue の番号。古い順）
    var comments: [Int: [LoopStatusComment]] = [:]
    var createdComments: [String] = []
    var updatedComments: [String] = []
    var deletedComments: [String] = []
    /// コメントの操作だけを失敗させる（Issue の操作は `fails`）
    var commentsFail = false
}

// FakeGitHub の、状態用の Issue（loop-status）まわり
extension FakeGitHub {
    var loopStatusIssuesByNumber: [Int: LoopStatusIssueRecord] {
        state.withLock { $0.loopStatus.issues }
    }

    var createdLoopStatusIssues: [String] {
        state.withLock { $0.loopStatus.createdIssues }
    }

    var updatedLoopStatusIssues: [String] {
        state.withLock { $0.loopStatus.updatedIssues }
    }

    var loopStatusIssueListings: Int {
        state.withLock { $0.loopStatus.issueListings }
    }

    func setLoopStatusIssues(_ issues: [LoopStatusIssueRecord]) {
        state.withLock { $0.loopStatus.issues = Dictionary(uniqueKeysWithValues: issues.map { ($0.number, $0) }) }
    }

    func setLoopStatusFails(_ fails: Bool) {
        state.withLock { $0.loopStatus.fails = fails }
    }

    func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        try state.withLock { state in
            if state.loopStatus.fails {
                throw TestError()
            }
            state.loopStatus.issueListings += 1
            return state.loopStatus.issues.values.sorted { $0.number < $1.number }
        }
    }

    func loopStatusIssue(in repository: String, number: Int) async throws -> LoopStatusIssueRecord? {
        try state.withLock { state in
            if state.loopStatus.fails {
                throw TestError()
            }
            state.loopStatus.readIssues.append("\(repository)#\(number)")
            return state.loopStatus.issues[number]
        }
    }

    func createLoopStatusIssue(in repository: String, body: String) async throws -> Int {
        try state.withLock { state in
            if state.loopStatus.fails {
                throw TestError()
            }
            let number = (state.loopStatus.issues.keys.max() ?? 100) + 1
            state.loopStatus.issues[number] = LoopStatusIssueRecord(
                number: number, author: "mrs1669", isOpen: true, updatedAt: Date(timeIntervalSince1970: 0), body: body
            )
            state.loopStatus.createdIssues.append("\(repository)#\(number)")
            return number
        }
    }

    func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws {
        try state.withLock { state in
            guard !state.loopStatus.fails, let issue = state.loopStatus.issues[number] else {
                throw TestError()
            }
            state.loopStatus.issues[number] = LoopStatusIssueRecord(
                number: number, author: issue.author, isOpen: true, updatedAt: issue.updatedAt, body: body
            )
            state.loopStatus.updatedIssues.append("\(repository)#\(number)")
        }
    }

    var loopStatusCommentsByIssue: [Int: [LoopStatusComment]] {
        state.withLock { $0.loopStatus.comments }
    }

    /// 作ったコメント（`<repo>#<Issue の番号>`）
    var createdLoopStatusComments: [String] {
        state.withLock { $0.loopStatus.createdComments }
    }

    /// 書き換えたコメント（`<repo> <コメントの id>`）
    var updatedLoopStatusComments: [String] {
        state.withLock { $0.loopStatus.updatedComments }
    }

    /// 消したコメント（`<repo> <コメントの id>`）
    var deletedLoopStatusComments: [String] {
        state.withLock { $0.loopStatus.deletedComments }
    }

    func setLoopStatusComments(_ comments: [LoopStatusComment], onIssue number: Int) {
        state.withLock { $0.loopStatus.comments[number] = comments }
    }

    func setLoopStatusCommentsFail(_ fails: Bool) {
        state.withLock { $0.loopStatus.commentsFail = fails }
    }

    func loopStatusComments(in repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        try state.withLock { state in
            if state.loopStatus.fails || state.loopStatus.commentsFail {
                throw TestError()
            }
            return state.loopStatus.comments[number] ?? []
        }
    }

    func createLoopStatusComment(in repository: String, issue number: Int, body: String) async throws -> Int {
        try state.withLock { state in
            guard !state.loopStatus.fails, !state.loopStatus.commentsFail, state.loopStatus.issues[number] != nil else {
                throw TestError()
            }
            // GitHub と同じく、id はリポジトリの Issue をまたいで一意
            let id = (state.loopStatus.comments.values.joined().map(\.id).max() ?? 1_000) + 1
            state.loopStatus.comments[number, default: []].append(
                LoopStatusComment(id: id, author: "mrs1669", updatedAt: Date(timeIntervalSince1970: 0), body: body)
            )
            state.loopStatus.createdComments.append("\(repository)#\(number)")
            return id
        }
    }

    func updateLoopStatusComment(in repository: String, id: Int, body: String) async throws {
        try state.withLock { state in
            guard !state.loopStatus.fails, !state.loopStatus.commentsFail,
                  let number = state.loopStatus.comments.first(where: { $0.value.contains { $0.id == id } })?.key,
                  let index = state.loopStatus.comments[number]?.firstIndex(where: { $0.id == id }) else {
                throw TestError()
            }
            state.loopStatus.comments[number]?[index].body = body
            state.loopStatus.updatedComments.append("\(repository) \(id)")
        }
    }

    func deleteLoopStatusComment(in repository: String, id: Int) async throws {
        try state.withLock { state in
            if state.loopStatus.fails || state.loopStatus.commentsFail {
                throw TestError()
            }
            // GitHub と同じく、既に無いコメントを消しても失敗しない
            for number in state.loopStatus.comments.keys {
                state.loopStatus.comments[number]?.removeAll { $0.id == id }
            }
            state.loopStatus.deletedComments.append("\(repository) \(id)")
        }
    }

    /// Issue のコメントから読んだ、自動ループの状態（最後に作ったコメント）
    func loopCommentReport(onIssue number: Int = 101) -> LoopStatusReport? {
        loopStatusCommentsByIssue[number]?.last.flatMap { LoopStatusReport.parse($0.body) }
    }

    /// 本文から読んだ、リポジトリ全体の状態
    func repositoryStatus(onIssue number: Int = 101) -> RepositoryStatusReport? {
        loopStatusIssuesByNumber[number].flatMap { RepositoryStatusReport.parse($0.body) }
    }
}
