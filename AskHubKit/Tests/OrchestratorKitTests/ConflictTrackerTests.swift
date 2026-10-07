import Foundation
@testable import OrchestratorKit
import Testing

struct ConflictTrackerTests {
    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            org: "shilokuma-inc",
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "prime-pick-ios", checkoutPath: "/src/prime-pick-ios")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/Users/me/.local/bin/askhub-start-loop", "{repository}"])
        )
    }

    private func pullRequest(repository: String = "shilokuma-inc/prime-pick-ios", base: String = "b1") -> ConflictingPullRequest {
        ConflictingPullRequest(
            repository: repository, number: 224, headBranch: "epic/ta-score", baseBranch: "develop", headSHA: "h1", baseSHA: base
        )
    }

    @Test func triesEachCombinationOnceAndGivesUpAfterRepeatedFailures() throws {
        let config = try config()
        var tracker = ConflictTracker()
        // 担当外のリポジトリは扱わない
        #expect(tracker.next(in: [pullRequest(repository: "shilokuma-inc/other")], config: config) == nil)

        #expect(tracker.next(in: [pullRequest()], config: config)?.0 == pullRequest())
        let gaveUpFirst = tracker.record(.unresolved(reason: "x"), for: pullRequest())
        #expect(!gaveUpFirst)
        // 同じ組み合わせ（epic と develop のコミット）では試し直さない
        #expect(tracker.next(in: [pullRequest()], config: config) == nil)

        // develop が進めば試し直す。続けて失敗したらあきらめる
        #expect(tracker.next(in: [pullRequest(base: "b2")], config: config) != nil)
        let gaveUpSecond = tracker.record(.unresolved(reason: "x"), for: pullRequest(base: "b2"))
        let gaveUpThird = tracker.record(.unresolved(reason: "x"), for: pullRequest(base: "b3"))
        #expect(!gaveUpSecond)
        #expect(gaveUpThird)
        #expect(tracker.next(in: [pullRequest(base: "b4")], config: config) == nil)

        // コンフリクトが無くなれば（検索に出なくなれば）忘れる
        tracker.prune(keeping: [])
        #expect(tracker.next(in: [pullRequest(base: "b4")], config: config) != nil)
    }

    @Test func readsOutcomeFromLastResultLine() {
        #expect(ConflictTracker.outcome(in: "ログ\nASKHUB_RESULT: resolved\n") == .resolved)
        #expect(ConflictTracker.outcome(in: "ASKHUB_RESULT: merged") == .merged)
        #expect(ConflictTracker.outcome(in: "ASKHUB_RESULT: unresolved 意図が両立しない") == .unresolved(reason: "意図が両立しない"))
        #expect(ConflictTracker.outcome(in: "ASKHUB_RESULT: unresolved") == .unresolved(reason: "理由は出力されませんでした"))
        #expect(ConflictTracker.outcome(in: "途中で落ちた") == nil)
    }

    @Test func defaultCommandSitsBesideLoopCommand() throws {
        let command = try config().conflictCommand.render(
            for: RepositoryConfig(owner: "shilokuma-inc", name: "prime-pick-ios", checkoutPath: "/src/prime-pick-ios"),
            pullRequest: pullRequest()
        )
        #expect(command == [
            "/Users/me/.local/bin/askhub-resolve-conflict", "shilokuma-inc/prime-pick-ios", "/src/prime-pick-ios",
            "epic/ta-score", "develop", "224"
        ])
        #expect(throws: OrchestratorConfigError.unknownConflictPlaceholder("pr")) {
            try ConflictCommandTemplate(arguments: ["x", "{pr}"])
        }
    }
}
