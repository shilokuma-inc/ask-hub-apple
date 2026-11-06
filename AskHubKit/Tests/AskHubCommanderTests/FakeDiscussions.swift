@testable import AskHubCommander
import AskHubProtocol
import Foundation
import os

/// メモリーの中の GitHub の Discussions。呼ばれた操作を残し、失敗や欠けた一覧を作れる
final class FakeDiscussions: DiscussionAPI {
    struct Stored: Sendable {
        var id: String
        var number: Int
        var title: String
        var body: String
        var viewerDidAuthor: Bool
        var createdAt: Date
        var comments: [DiscussionThread.Comment] = []
    }

    struct State: Sendable {
        var repository = DiscussionRepository(id: "R_1", discussionsEnabled: true, categories: [.init(id: "C_ideas", name: "Ideas")])
        var discussions: [Stored] = []
        var calls: [String] = []
        var nextID = 1
        /// 次に失敗させる操作と失敗
        var failures: [String: DiscussionError] = [:]
        /// コメントの一覧を空で返す（GitHub の障害で一覧が欠ける様子）
        var hidesComments = false
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    var calls: [String] { state.withLock { $0.calls } }
    var discussions: [Stored] { state.withLock { $0.discussions } }

    /// 書き込みの操作の数
    var writes: Int { calls.filter { ["createDiscussion", "updateDiscussion", "addComment", "updateComment"].contains($0) }.count }

    func change(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    private func call(_ name: String) throws(DiscussionError) {
        let failure = state.withLock { state -> DiscussionError? in
            state.calls.append(name)
            return state.failures.removeValue(forKey: name)
        }
        if let failure { throw failure }
    }

    private func newID(_ prefix: String) -> String {
        state.withLock { state in
            defer { state.nextID += 1 }
            return "\(prefix)_\(state.nextID)"
        }
    }

    func repository(_ repo: RepositoryFullName) async throws(DiscussionError) -> DiscussionRepository {
        try call("repository")
        return state.withLock { $0.repository }
    }

    func discussion(_ repo: RepositoryFullName, number: Int) async throws(DiscussionError) -> DiscussionThread? {
        try call("discussion")
        return state.withLock { state in
            state.discussions.first { $0.number == number }.map { stored in
                var thread = DiscussionThread(
                    id: stored.id, number: stored.number, title: stored.title, body: stored.body, viewerDidAuthor: stored.viewerDidAuthor
                )
                thread.comments = state.hidesComments ? [] : stored.comments
                return thread
            }
        }
    }

    func discussions(_ repo: RepositoryFullName, createdSince since: Date) async throws(DiscussionError) -> [DiscussionSummary] {
        try call("discussions")
        return state.withLock { state in
            state.discussions.reversed().filter { $0.createdAt >= since }.map {
                DiscussionSummary(id: $0.id, number: $0.number, body: $0.body, viewerDidAuthor: $0.viewerDidAuthor, createdAt: $0.createdAt)
            }
        }
    }

    func missing(_ ids: [String]) async throws(DiscussionError) -> Set<String> {
        try call("missing")
        let known = state.withLock { state in
            Set(state.discussions.flatMap { $0.comments.flatMap { [$0.post.id] + $0.replies.map(\.id) } })
        }
        return Set(ids.filter { !known.contains($0) })
    }

    func createDiscussion(
        repository: String,
        category: String,
        title: String,
        body: String
    ) async throws(DiscussionError) -> DiscussionSummary {
        try call("createDiscussion")
        let id = newID("D")
        let created = state.withLock { state in
            let number = (state.discussions.map(\.number).max() ?? 0) + 1
            let stored = Stored(id: id, number: number, title: title, body: body, viewerDidAuthor: true, createdAt: now())
            state.discussions.append(stored)
            return stored
        }
        return DiscussionSummary(id: created.id, number: created.number, body: body, viewerDidAuthor: true, createdAt: created.createdAt)
    }

    func updateDiscussion(_ id: String, title: String, body: String) async throws(DiscussionError) {
        try call("updateDiscussion")
        state.withLock { state in
            guard let index = state.discussions.firstIndex(where: { $0.id == id }) else { return }
            state.discussions[index].title = title
            state.discussions[index].body = body
        }
    }

    func addComment(to discussion: String, replyingTo parent: String?, body: String) async throws(DiscussionError) -> String {
        try call("addComment")
        let id = newID("DC")
        state.withLock { state in
            guard let index = state.discussions.firstIndex(where: { $0.id == discussion }) else { return }
            let post = DiscussionPost(id: id, body: body, viewerDidAuthor: true)
            if let parent, let comment = state.discussions[index].comments.firstIndex(where: { $0.post.id == parent }) {
                state.discussions[index].comments[comment].replies.append(post)
            } else {
                state.discussions[index].comments.append(.init(post: post))
            }
        }
        return id
    }

    func updateComment(_ id: String, body: String) async throws(DiscussionError) {
        try call("updateComment")
        state.withLock { state in
            for index in state.discussions.indices {
                for comment in state.discussions[index].comments.indices {
                    if state.discussions[index].comments[comment].post.id == id {
                        state.discussions[index].comments[comment].post.body = body
                    }
                    for reply in state.discussions[index].comments[comment].replies.indices
                    where state.discussions[index].comments[comment].replies[reply].id == id {
                        state.discussions[index].comments[comment].replies[reply].body = body
                    }
                }
            }
        }
    }

    /// コメント（返信を含む）を消す
    func delete(_ id: String) {
        state.withLock { state in
            for index in state.discussions.indices {
                state.discussions[index].comments.removeAll { $0.post.id == id }
            }
        }
    }

    /// Discussion のすべてのコメントの本文（返信は質問のコメントの後に並べる）
    func texts(of number: Int) -> [String] {
        state.withLock { state in
            state.discussions.first { $0.number == number }?.comments.flatMap { [$0.post.body] + $0.replies.map(\.body) } ?? []
        }
    }
}
