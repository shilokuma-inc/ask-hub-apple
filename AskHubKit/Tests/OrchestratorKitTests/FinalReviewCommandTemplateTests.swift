import Foundation
@testable import OrchestratorKit
import Testing

struct FinalReviewCommandTemplateTests {
    private let loader = OrchestratorConfigLoader(homeDirectory: "/Users/tester")
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    private let pullRequest = FinalReviewPullRequest(
        repository: "shilokuma-inc/ask-hub-apple",
        number: 503,
        headBranch: "epic/final-review",
        baseBranch: "develop",
        headSHA: "0123456789abcdef0123456789abcdef01234567"
    )

    private func decode(_ extra: String = "", loopCommand: String = "/Users/me/.local/bin/askhub-start-loop") throws -> OrchestratorConfig {
        let json = #"""
            { "repositories": [{ "repository": "shilokuma-inc/ask-hub-apple", "path": "/src/ask-hub-apple" }],
              "loopCommand": ["\#(loopCommand)", "{repository}"]\#(extra) }
            """#
        return try loader.decode(Data(json.utf8))
    }

    @Test func defaultCommandsSitBesideLoopCommand() throws {
        let config = try decode()
        #expect(config.reviewCommand.kind == .review)
        #expect(config.fixCommand.kind == .fix)
        let arguments = [
            "shilokuma-inc/ask-hub-apple", "/src/ask-hub-apple", "epic/final-review", "develop", "503",
            "0123456789abcdef0123456789abcdef01234567"
        ]
        #expect(config.reviewCommand.render(for: repository, pullRequest: pullRequest)
            == ["/Users/me/.local/bin/askhub-review-final"] + arguments)
        #expect(config.fixCommand.render(for: repository, pullRequest: pullRequest)
            == ["/Users/me/.local/bin/askhub-fix-review"] + arguments)
    }

    @Test func fixWaitsLongerThanReview() {
        #expect(FinalReviewCommandTemplate.Kind.review.timeout == .seconds(30 * 60))
        #expect(FinalReviewCommandTemplate.Kind.fix.timeout == .seconds(60 * 60))
    }

    @Test func defaultCommandsUseScriptNameWhenLoopCommandIsRelative() throws {
        let config = try decode(loopCommand: "askhub-start-loop")
        #expect(config.reviewCommand.arguments.first == "askhub-review-final")
        #expect(config.fixCommand.arguments.first == "askhub-fix-review")
    }

    @Test func readsConfiguredCommands() throws {
        let config = try decode(#"""
            , "reviewCommand": ["/opt/review", "--pr", "{pullRequest}", "--sha", "{headSHA}"],
              "fixCommand": ["/opt/fix", "{repository}#{pullRequest}@{headBranch}"]
            """#)
        #expect(config.reviewCommand.render(for: repository, pullRequest: pullRequest) == [
            "/opt/review", "--pr", "503", "--sha", "0123456789abcdef0123456789abcdef01234567"
        ])
        #expect(config.fixCommand.render(for: repository, pullRequest: pullRequest) == [
            "/opt/fix", "shilokuma-inc/ask-hub-apple#503@epic/final-review"
        ])
    }

    @Test func rejectsEmptyCommandOrUnknownPlaceholder() {
        #expect(throws: OrchestratorConfigError.emptyFinalReviewCommand(key: "reviewCommand")) {
            try decode(#", "reviewCommand": []"#)
        }
        #expect(throws: OrchestratorConfigError.emptyFinalReviewCommand(key: "fixCommand")) {
            try decode(#", "fixCommand": [""]"#)
        }
        #expect(throws: OrchestratorConfigError.unknownFinalReviewPlaceholder(key: "fixCommand", name: "controlPath")) {
            try decode(#", "fixCommand": ["/opt/fix", "{controlPath}"]"#)
        }
        #expect(throws: OrchestratorConfigError.unknownFinalReviewPlaceholder(key: "reviewCommand", name: "sha")) {
            try FinalReviewCommandTemplate(.review, arguments: ["x", "{sha}"])
        }
    }

    @Test func errorMessagesNameTheKeyAndPlaceholders() {
        #expect(OrchestratorConfigError.emptyFinalReviewCommand(key: "reviewCommand").description
            == "reviewCommand が空です。実行するコマンドを引数の配列で指定してください")
        #expect(OrchestratorConfigError.unknownFinalReviewPlaceholder(key: "fixCommand", name: "pr").description
            == "fixCommand に未知のプレースホルダ {pr} があります（使えるもの: "
            + "{repository} {checkoutPath} {headBranch} {baseBranch} {pullRequest} {headSHA}）")
    }
}
