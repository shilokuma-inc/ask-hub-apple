import Foundation
@testable import OrchestratorKit
import Testing

struct ConflictTrackerTests {
    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [
                RepositoryConfig(owner: "shilokuma-inc", name: "prime-pick-ios", checkoutPath: "/src/prime-pick-ios"),
                RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
            ],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/Users/me/.local/bin/askhub-start-loop", "{repository}"])
        )
    }

    private func pullRequest(
        repository: String = "shilokuma-inc/prime-pick-ios", number: Int = 224, base: String = "b1"
    ) -> ConflictingPullRequest {
        ConflictingPullRequest(
            repository: repository, number: number, headBranch: "epic/ta-score", baseBranch: "develop", headSHA: "h1", baseSHA: base
        )
    }

    /// 今から始める PR の番号
    private func startableNumbers(
        _ tracker: ConflictTracker, in pullRequests: [ConflictingPullRequest], config: OrchestratorConfig
    ) -> [Int] {
        tracker.startable(in: pullRequests, config: config).map(\.0.number)
    }

    @Test func triesEachCombinationOnceAndGivesUpAfterRepeatedFailures() throws {
        let config = try config()
        var tracker = ConflictTracker()
        // 担当外のリポジトリは扱わない
        #expect(startableNumbers(tracker, in: [pullRequest(repository: "shilokuma-inc/other")], config: config).isEmpty)

        #expect(tracker.startable(in: [pullRequest()], config: config).map(\.0) == [pullRequest()])
        let gaveUpFirst = tracker.record(.unresolved(reason: "x"), for: pullRequest())
        #expect(!gaveUpFirst)
        // 同じ組み合わせ（epic と develop のコミット）では試し直さない
        #expect(startableNumbers(tracker, in: [pullRequest()], config: config).isEmpty)

        // develop が進めば試し直す。続けて失敗したらあきらめる
        #expect(startableNumbers(tracker, in: [pullRequest(base: "b2")], config: config) == [224])
        let gaveUpSecond = tracker.record(.unresolved(reason: "x"), for: pullRequest(base: "b2"))
        let gaveUpThird = tracker.record(.unresolved(reason: "x"), for: pullRequest(base: "b3"))
        #expect(!gaveUpSecond)
        #expect(gaveUpThird)
        #expect(startableNumbers(tracker, in: [pullRequest(base: "b4")], config: config).isEmpty)

        // コンフリクトが無くなれば（検索に出なくなれば）忘れる
        tracker.prune(keeping: [])
        #expect(startableNumbers(tracker, in: [pullRequest(base: "b4")], config: config) == [224])
    }

    @Test func startsOnePerRepositoryAndWaitsForRunningRepository() throws {
        let config = try config()
        var tracker = ConflictTracker()
        let pullRequests = [
            pullRequest(number: 224),
            pullRequest(number: 225),
            pullRequest(repository: "shilokuma-inc/ask-hub-apple", number: 50)
        ]
        // 同じリポジトリは 1 件ずつ、別のリポジトリは並べて始める
        #expect(startableNumbers(tracker, in: pullRequests, config: config) == [224, 50])

        tracker.start(pullRequest(number: 224))
        #expect(tracker.isRunning(in: "shilokuma-inc/Prime-Pick-iOS"))
        // 実行中のリポジトリのものは、ほかの PR も選ばない
        #expect(startableNumbers(tracker, in: pullRequests, config: config) == [50])

        // 終わったら、同じリポジトリの次の PR を選ぶ（試した組み合わせは選ばない）
        tracker.record(.resolved, for: pullRequest(number: 224))
        tracker.finish(pullRequest(number: 224))
        #expect(!tracker.isRunning(in: "shilokuma-inc/prime-pick-ios"))
        #expect(startableNumbers(tracker, in: pullRequests, config: config) == [225, 50])

        // 結果を記録せずに終えた（利用上限など）なら、同じ組み合わせを選び直す
        tracker.start(pullRequest(number: 225))
        tracker.finish(pullRequest(number: 225))
        #expect(startableNumbers(tracker, in: pullRequests, config: config) == [225, 50])
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
