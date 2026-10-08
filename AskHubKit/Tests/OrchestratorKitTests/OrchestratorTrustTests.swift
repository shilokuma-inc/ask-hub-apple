import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

/// リポジトリごとの書き込み権限を持つアカウントを返す
final class FakeWritersSource: RepositoryWritersSource {
    private let state: OSAllocatedUnfairLock<[String: [String]]>

    init(_ writers: [String: [String]]) {
        state = OSAllocatedUnfairLock(initialState: writers)
    }

    func set(_ writers: [String], of repository: String) {
        state.withLock { $0[repository] = writers }
    }

    func writers(of repository: String) async throws -> [String] {
        state.withLock { $0[repository] ?? [] }
    }
}

/// 担当リポジトリに書き込み権限を持つ共同開発者（partner）を、そのリポジトリで信用する
struct OrchestratorTrustTests {
    let logs = LogRecorder()
    static let hub = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    static let notti = RepositoryConfig(owner: "shilokuma-inc", name: "notti-ios", checkoutPath: "/src/notti-ios")

    func makeOrchestrator(
        github: FakeGitHub,
        runtime: FakeRuntime = FakeRuntime(),
        inbox: FakeInbox = FakeInbox(),
        writers: FakeWritersSource = FakeWritersSource(["shilokuma-inc/ask-hub-apple": ["partner"]]),
        trustsRepositoryWriters: Bool = true
    ) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [Self.hub, Self.notti],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}", "{discussion}"]),
            trustsRepositoryWriters: trustsRepositoryWriters
        )
        let logs = logs
        return Orchestrator(
            config: config,
            github: github,
            inbox: inbox,
            runtime: runtime,
            log: { logs.append($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            repositoryWriters: RepositoryWriters(source: writers)
        )
    }

    static func discussion(in repository: String, number: Int) -> InboxSubject {
        InboxSubject(
            kind: .discussion,
            nodeID: "D_\(number)",
            repository: repository,
            number: number,
            title: "依頼",
            url: URL(string: "https://github.com/\(repository)/discussions/\(number)")!,
            author: "mrs1669"
        )
    }

    @Test func treatsAnswerOfRepositoryWriterAsAnswered() async throws {
        let github = FakeGitHub([.success([])])
        let inbox = FakeInbox()
        inbox.set(
            [Self.discussion(in: "shilokuma-inc/ask-hub-apple", number: 1), Self.discussion(in: "shilokuma-inc/notti-ios", number: 2)],
            threads: [
                "D_1": [OrchestratorTests.ask("C_1", replies: ["partner"])],
                "D_2": [OrchestratorTests.ask("C_2", replies: ["partner"])]
            ]
        )

        try await makeOrchestrator(github: github, inbox: inbox).pollOnce()

        // partner は ask-hub-apple にだけ書き込み権限がある。notti-ios では回答として数えない
        #expect(github.addedReady == ["D_1"])
        #expect(github.removedNeedsAnswer == ["D_1"])
    }

    @Test func passesTrustedAuthorsOfRepositoryToLoop() async throws {
        let github = FakeGitHub([.success([.fixture(repository: "shilokuma-inc/ask-hub-apple", number: 3)])])
        let runtime = FakeRuntime()

        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.count == 1)
        // 起動スクリプトが playbook に書く、信用する author
        #expect(runtime.launchEnvironments == [["ASKHUB_TRUSTED_AUTHORS": "mrs1669,partner"]])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple で信用する author: mrs1669, partner"))
    }

    @Test func launchesDiscussionCreatedByRepositoryWriter() async throws {
        let discussions: [ReadyDiscussion] = [
            .fixture(repository: "shilokuma-inc/ask-hub-apple", number: 3, author: "partner"),
            .fixture(repository: "shilokuma-inc/notti-ios", number: 4, author: "partner")
        ]
        let github = FakeGitHub([.success(discussions)])
        let runtime = FakeRuntime()

        let decisions = try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "3"]])
        #expect(decisions.contains { decision in
            if case let .skip(discussion, .untrustedAuthor) = decision {
                return discussion.number == 4
            }
            return false
        })
    }

    @Test func handlesIdeaRequestOfRepositoryWriter() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([
            .fixture(repository: "shilokuma-inc/ask-hub-apple", number: 7, author: "partner"),
            .fixture(repository: "shilokuma-inc/ask-hub-apple", number: 8, author: "someone")
        ])
        let runtime = FakeRuntime()
        let created = CommandResult(status: 0, output: "ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12\n")
        runtime.setRunResults([created])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        // 書き込み権限の無い someone の依頼は処理しない
        #expect(runtime.ran.count == 1)
        #expect(runtime.inputs.first?.contains("依頼 Issue: #7") == true)
        #expect(runtime.inputs.first?.contains("信用する author は mrs1669, partner") == true)
        #expect(github.closedIdeas == [7])
    }

    @Test func trustsOnlyConfiguredAuthorsWhenDisabled() async throws {
        let github = FakeGitHub([.success([])])
        let inbox = FakeInbox()
        inbox.set(
            [Self.discussion(in: "shilokuma-inc/ask-hub-apple", number: 1)],
            threads: ["D_1": [OrchestratorTests.ask("C_1", replies: ["partner"])]]
        )

        try await makeOrchestrator(github: github, inbox: inbox, trustsRepositoryWriters: false).pollOnce()

        #expect(github.addedReady.isEmpty)
        #expect(github.removedNeedsAnswer.isEmpty)
    }
}
