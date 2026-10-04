import Foundation
@testable import OrchestratorKit
import Testing

extension IdeaRequestIssue {
    static func fixture(repository: String = "shilokuma-inc/ask-hub-apple", number: Int = 7, author: String? = "mrs1669") -> Self {
        Self(
            nodeID: "I_\(number)",
            repository: repository,
            number: number,
            title: "【依頼】通知の頻度を調整したい",
            body: "朝だけにしたい",
            url: URL(string: "https://github.com/\(repository)/issues/\(number)")!,
            author: author
        )
    }
}

struct IdeaPromptTests {
    @Test func promptIncludesProtocolRequirements() {
        let prompt = IdeaPrompt.make(for: .fixture(), trustedAuthors: ["mrs1669"])
        // ゴールの注意点: 質問 1 つにつき 1 コメント・質問の目印・needs-answer の付与・信用する author の扱い
        #expect(prompt.contains("1 つにつき 1 コメント"))
        #expect(prompt.contains(#"<!-- ask-hub:question id="d<Discussion の番号>-q<連番>" options="選択肢1|選択肢2" -->"#))
        #expect(prompt.contains("`needs-answer` ラベルを付ける"))
        #expect(prompt.contains("信用する author（mrs1669）"))
        #expect(prompt.contains(IdeaPrompt.urlPrefix))
        // 依頼の内容（タイトルの【依頼】は外す）
        #expect(prompt.contains("タイトル: `通知の頻度を調整したい`"))
        #expect(prompt.contains("朝だけにしたい"))
        #expect(prompt.contains("コードの変更・コミット・push・PR の作成はしない"))
    }

    @Test func readsLastDiscussionURLOfSameRepository() {
        let output = """
            考察しました。
            ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/3
            作り直しました。
            `ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12`
            """
        let url = IdeaPrompt.discussionURL(in: output, repository: "Shilokuma-Inc/Ask-Hub-Apple")
        #expect(url?.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/discussions/12")
    }

    @Test(arguments: [
        "何も出力しなかった",
        "ASKHUB_DISCUSSION_URL: https://github.com/someone/else/discussions/1",
        "ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/issues/1",
        "ASKHUB_DISCUSSION_URL: http://github.com/shilokuma-inc/ask-hub-apple/discussions/1",
        "ASKHUB_DISCUSSION_URL: https://example.com/shilokuma-inc/ask-hub-apple/discussions/1",
        "ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/abc"
    ])
    func rejectsMissingOrUnexpectedURL(output: String) {
        #expect(IdeaPrompt.discussionURL(in: output, repository: "shilokuma-inc/ask-hub-apple") == nil)
    }
}

struct IdeaRequestTrackerTests {
    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            org: "shilokuma-inc",
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop"])
        )
    }

    @Test func picksOldestTrustedRequestOfAssignedRepository() throws {
        let tracker = IdeaRequestTracker()
        let issues: [IdeaRequestIssue] = [
            .fixture(number: 9),
            .fixture(number: 3, author: "someone"),
            .fixture(repository: "shilokuma-inc/notti-ios", number: 1),
            .fixture(number: 5)
        ]
        let next = tracker.next(in: issues, config: try config())
        #expect(next?.0.number == 5)
        #expect(next?.1.fullName == "shilokuma-inc/ask-hub-apple")
    }

    @Test func retriesOnceThenGivesUp() throws {
        var tracker = IdeaRequestTracker()
        let issue = IdeaRequestIssue.fixture()
        let gaveUpFirst = tracker.recordFailure(for: issue)
        #expect(!gaveUpFirst)
        #expect(tracker.attempts(of: issue) == 1)
        #expect(tracker.next(in: [issue], config: try config())?.0 == issue)
        let gaveUpSecond = tracker.recordFailure(for: issue)
        #expect(gaveUpSecond)
        #expect(tracker.next(in: [issue], config: try config()) == nil)
    }

    @Test func tracksCreatedDiscussionUntilCompletedAndPruned() throws {
        var tracker = IdeaRequestTracker()
        let issue = IdeaRequestIssue.fixture()
        let url = try #require(URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/12"))
        tracker.recordCreated(url, for: issue)

        // 作った後は、コメントとクローズだけを再試行し、Discussion を作り直さない
        #expect(tracker.next(in: [issue], config: try config()) == nil)
        #expect(tracker.pendingCompletions(in: [issue]).map(\.1) == [url])

        tracker.recordCompleted(issue)
        #expect(tracker.pendingCompletions(in: [issue]).isEmpty)
        #expect(tracker.next(in: [issue], config: try config()) == nil)

        tracker.prune(keeping: [])
        #expect(tracker.phases.isEmpty)
    }
}
