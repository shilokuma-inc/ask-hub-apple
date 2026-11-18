@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os
import Testing

/// やめた epic の PR を閉じる GitHub の操作の偽物。開いた PR を持ち、閉じた・コメントを書いたものを記録する
final class FakePullRequestClosing: PullRequestClosing {
    struct State {
        var pulls: [PullRequest] = []
        var lists: [(head: String?, base: String?)] = []
        var closes: [Int] = []
        var comments: [(number: Int, body: String)] = []
        /// コメントを書くときに返す失敗（PR ごとに 1 回だけ）
        var commentFailures: [Int: PullRequestError] = [:]
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    var current: State { state.withLock { $0 } }

    func update(_ change: @Sendable (inout State) -> Void) {
        state.withLock(change)
    }

    func openPullRequests(_ repo: RepositoryFullName, head: String?, base: String?) async throws(PullRequestError) -> [PullRequest] {
        state.withLock { state in
            state.lists.append((head, base))
            return state.pulls.filter { pull in
                pull.state == .open && (head.map { pull.headRef == $0 } ?? true) && (base.map { pull.baseRef == $0 } ?? true)
            }
        }
    }

    func close(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError) {
        state.withLock { state in
            state.closes.append(number)
            guard let index = state.pulls.firstIndex(where: { $0.number == number }) else { return }
            state.pulls[index].state = .closed
        }
    }

    func comment(_ repo: RepositoryFullName, number: Int, body: String) async throws(PullRequestError) {
        let failure = state.withLock { state -> PullRequestError? in
            guard let failure = state.commentFailures.removeValue(forKey: number) else {
                state.comments.append((number, body))
                return nil
            }
            return failure
        }
        if let failure { throw failure }
    }
}

/// 開始した後にやめた epic の、開いている子 PR と最終 PR を閉じる
struct AbandonedPullRequestsTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let mac = MacName(rawValue: "macbook")!
    static let epic = ULID(rawValue: "01JCJ0A0000000000000000001")!
    static let start = Date(timeIntervalSince1970: 1_793_757_600)
    static var branch: String { PrepareWorkspaceRunner.branch(of: epic) }

    let store = InMemoryStateStore()
    let github = FakePullRequestClosing()
    let clock = OSAllocatedUnfairLock(initialState: AbandonedPullRequestsTests.start)
    let logs = OSAllocatedUnfairLock<[String]>(initialState: [])

    func closer() -> AbandonedPullRequests {
        let context = CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { [clock] in clock.withLock { $0 } }
        return AbandonedPullRequests(context: context, github: github) { [logs] message in logs.withLock { $0.append(message) } }
    }

    func advance(minutes: Double) {
        clock.withLock { $0 = $0.addingTimeInterval(minutes * 60) }
    }

    /// ビルドの設定（最終 PR の向き先は develop）のあるリポジトリを置く
    func putRepository() async throws {
        var repository = RepositoryFile(repo: Self.repo, platform: .apple, maxConcurrentEpics: 1, addedAt: Timestamp(Self.start))
        repository.build = try RepositoryHandlersTests.build()
        try await StateFileStore(store: store).create(repository, at: StatePath.repository(Self.repo), message: "repo")
    }

    /// epic を置く。`mac` が nil なら開始する前の epic
    func put(_ id: ULID = epic, stage: EpicStage = .abandoned, mac: MacName? = mac, age: TimeInterval = 60) async throws {
        let time = Timestamp(Self.start.addingTimeInterval(-age))
        let file = EpicFile(
            id: id,
            repo: Self.repo,
            title: "ランキング",
            discussion: 7,
            stage: stage,
            mac: mac,
            branch: mac == nil ? nil : PrepareWorkspaceRunner.branch(of: id),
            createdAt: time,
            updatedAt: time
        )
        try await StateFileStore(store: store).create(file, at: StatePath.epic(Self.repo, id), message: "epic")
    }

    static func pull(_ number: Int, head: String, base: String) -> PullRequest {
        PullRequest(number: number, state: .open, merged: false, head: (head, String(repeating: "a", count: 40)), baseRef: base)
    }

    @Test func closesChildAndFinalPullRequestsWithComment() async throws {
        try await putRepository()
        try await put()
        let other = PrepareWorkspaceRunner.branch(of: ULID(rawValue: "01JCJ0A0000000000000000002")!)
        github.update {
            $0.pulls = [
                Self.pull(11, head: "\(Self.branch)/t1", base: Self.branch),
                Self.pull(12, head: "\(Self.branch)/t2", base: Self.branch),
                Self.pull(13, head: Self.branch, base: "develop"),
                // 作業ブランチから base 以外への PR は、最終 PR ではないので閉じない
                Self.pull(16, head: Self.branch, base: "release/1.0"),
                Self.pull(14, head: "feat/other", base: "develop"),
                Self.pull(15, head: "\(other)/t1", base: other)
            ]
        }
        await closer().closeAll()
        let current = github.current
        #expect(current.pulls.filter { $0.state == .closed }.map(\.number) == [11, 12, 13])
        #expect(current.comments.map(\.number) == [11, 12, 13])
        #expect(current.lists.map(\.base) == [Self.branch, "develop"])
        let comment = try #require(current.comments.first?.body)
        #expect(comment.contains("元の依頼（依頼: #7）を取り下げたので、マージせずに閉じました"))
        #expect(comment.contains("ブランチは消さずに残しています"))
        let marker = try #require(ProtocolMarker.parse(comment))
        #expect(marker.value == .object(["type": .string("abandoned"), "epic": .string(Self.epic.rawValue)]))
        #expect(logs.withLock { $0 }.contains { $0.contains("#11・#12・#13") })
    }

    /// 開始する前にやめた epic・やめてから 1 日を過ぎた epic・動いている epic は見ない（GitHub を読まない）
    @Test func skipsEpicsThatHaveNoPullRequestsToClose() async throws {
        try await put(ULID(rawValue: "01JCJ0A0000000000000000002")!, mac: nil)
        try await put(ULID(rawValue: "01JCJ0A0000000000000000003")!, age: 25 * 60 * 60)
        try await put(ULID(rawValue: "01JCJ0A0000000000000000004")!, stage: .running)
        try await put(ULID(rawValue: "01JCJ0A0000000000000000005")!, stage: .merged)
        await closer().closeAll()
        #expect(github.current.lists.isEmpty)
    }

    /// やめたときに動いていたジョブが後から作った PR も、見直しで閉じる。見直しの間より前には GitHub を読まない
    @Test func rechecksForPullRequestsOpenedLater() async throws {
        try await put()
        let closer = closer()
        await closer.closeAll()
        #expect(github.current.lists.count == 2)

        github.update { $0.pulls = [Self.pull(21, head: "\(Self.branch)/t3", base: Self.branch)] }
        advance(minutes: 10)
        await closer.closeAll()
        #expect(github.current.lists.count == 2)

        advance(minutes: 21)
        await closer.closeAll()
        #expect(github.current.pulls.map(\.state) == [.closed])
        #expect(github.current.comments.map(\.number) == [21])
    }

    /// 閉じた後にコメントを書けなかったら、ほかの PR は閉じ続け、後でコメントだけを書き直す（閉じ直さない・コメントを重ねない）
    @Test func retriesCommentAfterFailureWithoutStoppingOthers() async throws {
        try await put()
        github.update {
            $0.pulls = [
                Self.pull(11, head: "\(Self.branch)/t1", base: Self.branch),
                Self.pull(12, head: "\(Self.branch)/t2", base: Self.branch)
            ]
            $0.commentFailures = [11: .serverError(status: 502)]
        }
        let closer = closer()
        await closer.closeAll()
        #expect(github.current.pulls.map(\.state) == [.closed, .closed])
        #expect(github.current.comments.map(\.number) == [12])
        #expect(await closer.uncommented[Self.epic] == [11])

        advance(minutes: 1)
        await closer.closeAll()
        #expect(github.current.comments.map(\.number) == [12])

        advance(minutes: 5)
        await closer.closeAll()
        #expect(github.current.comments.map(\.number) == [12, 11])
        #expect(github.current.closes == [11, 12])
        #expect(await closer.uncommented[Self.epic]?.isEmpty != false)
    }

    /// 見る期間の終わりにコメントを書けなくても、期間を過ぎてからコメントだけを書き直す（PR は探さない）
    @Test func retriesCommentAfterWindow() async throws {
        try await put(age: 24 * 60 * 60 + 29 * 60)
        github.update {
            $0.pulls = [Self.pull(11, head: "\(Self.branch)/t1", base: Self.branch)]
            $0.commentFailures = [11: .serverError(status: 502)]
        }
        let closer = closer()
        await closer.closeAll()
        #expect(github.current.closes == [11])
        #expect(github.current.lists.count == 2)

        advance(minutes: 6)
        await closer.closeAll()
        #expect(github.current.comments.map(\.number) == [11])
        #expect(github.current.lists.count == 2)
    }
}
