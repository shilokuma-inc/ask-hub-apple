@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 終わった epic の Discussion の写しを閉じる
extension ClaudeJobRunnerTests {
    /// 写しを作った後に epic を終える（マージなら、最終 PR とマージのコミットも書く）
    func finish(_ epic: EpicFile, as stage: EpicStage, in store: InMemoryStateStore) async throws {
        let path = StatePath.epic(Self.repo, epic.id)
        var ended = try #require(try await read(EpicFile.self, at: path, in: store))
        ended.stage = stage
        if stage == .merged {
            ended.finalPullRequest = 42
            ended.merge = .init(commit: "abcdef0" + String(repeating: "1", count: 33), at: Timestamp(Self.now))
        }
        ended.updatedAt = Timestamp(Self.now)
        try await put(ended, at: path, in: store)
    }

    /// 締めのコメント（目印の type が closing）の本文
    func closingTexts(of number: Int, in github: FakeDiscussions) -> [String] {
        github.texts(of: number).filter { ProtocolMarker.parse($0)?.value["type"] == .string("closing") }
    }

    @Test func closesMergedEpicAfterClosingComment() async throws {
        let (store, epic) = try await asking()
        let github = FakeDiscussions { Self.now }
        let mirror = mirror(store, github: github)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        // 終わっていない epic は閉じない
        #expect(closingTexts(of: number, in: github).isEmpty)
        #expect(github.discussions.first?.closed == nil)
        try await finish(epic, as: .merged, in: store)
        await mirror.syncAll(verifier: verifier)
        #expect(closingTexts(of: number, in: github) == [
            ProtocolMarker.text(
                body: "最終 PR #42 をマージしました（`abcdef0`）。この Discussion を閉じます。",
                marker: DiscussionCopies.marker("closing", epic: epic.id)
            )
        ])
        #expect(github.discussions.first?.closed == .resolved)
        #expect(github.discussions.first?.body.contains("マージしました") == true)
        // 閉じた後は、書き足さない
        let calls = github.calls.count
        await mirror.syncAll(verifier: verifier)
        #expect(github.calls.count == calls)
    }

    @Test func closesAbandonedEpicAsOutdated() async throws {
        let (store, epic) = try await asking()
        let github = FakeDiscussions { Self.now }
        let mirror = mirror(store, github: github)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        try await finish(epic, as: .abandoned, in: store)
        await mirror.syncAll(verifier: verifier)
        let closing = try #require(closingTexts(of: number, in: github).first)
        #expect(closing.hasPrefix("この依頼はやめました。この Discussion を閉じます。"))
        #expect(github.discussions.first?.closed == .outdated)
    }

    @Test func doesNotCloseDiscussionReopenedAfterClosing() async throws {
        let (store, epic) = try await asking()
        let github = FakeDiscussions { Self.now }
        await mirror(store, github: github).syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        try await finish(epic, as: .merged, in: store)
        await mirror(store, github: github).syncAll(verifier: verifier)
        #expect(github.discussions.first?.closed == .resolved)
        // 人が開き直した後に、司令塔を起動し直して照らし合わせても、閉じ直さず、締めのコメントも重ねない
        github.reopen(number)
        let logs = LogLines()
        let closes = github.calls.filter { $0 == "closeDiscussion" }.count
        await mirror(store, github: github, logs: logs).syncAll(verifier: verifier)
        #expect(github.discussions.first?.closed == nil)
        #expect(github.calls.filter { $0 == "closeDiscussion" }.count == closes)
        #expect(closingTexts(of: number, in: github).count == 1)
        #expect(logs.lines.contains { $0.contains("開き直されたので、閉じ直さない") })
    }

    @Test func closesAgainWhenClosingFailedAfterComment() async throws {
        let (store, epic) = try await asking()
        let github = FakeDiscussions { Self.now }
        let clock = TestClock(Self.now)
        let mirror = mirror(store, github: github, clock: clock)
        await mirror.syncAll(verifier: verifier)
        let number = try await discussionNumber(of: epic, in: store)
        try await finish(epic, as: .merged, in: store)
        github.change { $0.failures["closeDiscussion"] = .http(.serverError(status: 502)) }
        await mirror.syncAll(verifier: verifier)
        #expect(closingTexts(of: number, in: github).count == 1)
        #expect(github.discussions.first?.closed == nil)
        // 間を空けた次の周で、締めのコメントを重ねずに閉じ直す
        clock.advance(minutes: 60)
        await mirror.syncAll(verifier: verifier)
        #expect(github.discussions.first?.closed == .resolved)
        #expect(closingTexts(of: number, in: github).count == 1)
    }
}
