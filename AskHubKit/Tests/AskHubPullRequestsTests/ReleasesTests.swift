@testable import AskHubPullRequests
import Foundation
import Testing

/// 配信の後作業に使う GitHub の操作（Upload の実行・タグ・Release・版を上げるコミット）
struct ReleasesTests {
    static let tagObject = String(repeating: "c", count: 40)
    static let tree = String(repeating: "d", count: 40)
    static let date = Date(timeIntervalSince1970: 1_794_490_551)
    static let takumi = GitIdentity(name: "Takumi", email: "1+mrs1669@users.noreply.github.com")

    // MARK: - Actions の実行

    @Test func listsRunsCreatedInRange() async throws {
        let run = #"{"id":19000000001,"run_number":13,"path":".github/workflows/upload.yml","head_sha":"\#(Fixture.sha)","event":"push","#
            + #""created_at":"2026-10-18T13:00:00Z","run_started_at":"2026-10-18T13:01:00Z","updated_at":"2026-10-18T13:40:00Z"}"#
        let broken = #"{"id":2,"run_number":14,"path":".github/workflows/upload.yml"}"#
        let transport = StubTransport([.json(200, #"{"total_count":2,"workflow_runs":[\#(run),\#(broken)]}"#)])
        let runs = try await Fixture.client(transport).workflowRuns(
            createdFrom: Date(timeIntervalSince1970: 1_792_324_800), to: Date(timeIntervalSince1970: 1_792_346_400)
        )
        // 欄の欠けた実行は飛ばす
        #expect(runs.map(\.runNumber) == [13])
        #expect(runs.first?.headSHA == Fixture.sha)
        #expect(runs.first?.path == ".github/workflows/upload.yml")
        #expect(Fixture.query(transport.requests.first)["created"] == "2026-10-18T12:00:00Z..2026-10-18T18:00:00Z")
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs")
    }

    // MARK: - タグ

    @Test func followsAnnotatedTagToCommit() async throws {
        let transport = StubTransport([
            .json(200, #"{"ref":"refs/tags/v1.0.0","object":{"sha":"\#(Self.tagObject)","type":"tag"}}"#),
            .json(200, #"{"sha":"\#(Self.tagObject)","object":{"sha":"\#(Fixture.sha)","type":"commit"}}"#)
        ])
        #expect(try await Fixture.client(transport).tagCommit("v1.0.0") == Fixture.sha)
        #expect(transport.requests.map(Fixture.path) == [
            "/repos/shilokuma-inc/ask-hub-apple/git/ref/tags/v1.0.0", "/repos/shilokuma-inc/ask-hub-apple/git/tags/\(Self.tagObject)"
        ])
    }

    @Test func readsLightweightTagAndMissingTag() async throws {
        let commitRef = #"{"ref":"refs/tags/v1.0.0","object":{"sha":"\#(Fixture.sha)","type":"commit"}}"#
        let lightweight = StubTransport([.json(200, commitRef)])
        #expect(try await Fixture.client(lightweight).tagCommit("v1.0.0") == Fixture.sha)
        let missing = StubTransport([.json(404, #"{"message":"Not Found"}"#)])
        #expect(try await Fixture.client(missing).tagCommit("v1.0.0") == nil)
    }

    @Test(arguments: ["release/1.0.0", "-v1", "v1..0", ""])
    func refusesMalformedTagNames(_ name: String) async {
        await #expect(throws: PullRequestError.self) {
            try await Fixture.client(StubTransport([])).tagCommit(name)
        }
    }

    @Test func createsAnnotatedTagThenRef() async throws {
        let transport = StubTransport([
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, #"{"sha":"\#(Self.tagObject)"}"#),
            .json(201, #"{"ref":"refs/tags/v1.1.0","object":{"sha":"\#(Self.tagObject)","type":"tag"}}"#)
        ])
        try await Fixture.client(transport).createAnnotatedTag(
            "v1.1.0", commit: Fixture.sha, message: "OshiCon 1.1.0 (31)\n", tagger: Self.takumi, date: Self.date
        )
        let tag = Fixture.body(transport.requests[1])
        #expect(tag["tag"] as? String == "v1.1.0")
        #expect(tag["object"] as? String == Fixture.sha)
        #expect(tag["type"] as? String == "commit")
        let tagger = tag["tagger"] as? [String: String]
        #expect(tagger == ["name": "Takumi", "email": "1+mrs1669@users.noreply.github.com", "date": "2026-11-12T13:35:51Z"])
        let ref = Fixture.body(transport.requests[2])
        #expect(ref["ref"] as? String == "refs/tags/v1.1.0")
        #expect(ref["sha"] as? String == Self.tagObject)
    }

    @Test func keepsTagThatAlreadyPointsToCommitAndRefusesOther() async throws {
        let pointing = #"{"ref":"refs/tags/v1.1.0","object":{"sha":"\#(Fixture.sha)","type":"commit"}}"#
        let same = StubTransport([.json(200, pointing)])
        try await Fixture.client(same).createAnnotatedTag("v1.1.0", commit: Fixture.sha, message: "m", tagger: Self.takumi, date: Self.date)
        #expect(same.requests.count == 1)
        // 人が手で付けたタグを動かさない
        let moved = #"{"ref":"refs/tags/v1.1.0","object":{"sha":"\#(Fixture.otherSHA)","type":"commit"}}"#
        let other = StubTransport([.json(200, moved)])
        await #expect(throws: PullRequestError.self) {
            try await Fixture.client(other).createAnnotatedTag(
                "v1.1.0",
                commit: Fixture.sha,
                message: "m",
                tagger: Self.takumi,
                date: Self.date
            )
        }
    }

    // MARK: - GitHub Release

    @Test func publishesReleaseAsLatestUnlessItExists() async throws {
        let created = #"{"html_url":"https://github.com/shilokuma-inc/ask-hub-apple/releases/tag/v1.1.0","tag_name":"v1.1.0"}"#
        let transport = StubTransport([.json(404, #"{"message":"Not Found"}"#), .json(201, created)])
        let release = try await Fixture.client(transport).publishRelease(tag: "v1.1.0", body: "## 新しい機能")
        #expect(release.url.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/releases/tag/v1.1.0")
        let body = Fixture.body(transport.requests[1])
        #expect(body["tag_name"] as? String == "v1.1.0")
        #expect(body["name"] as? String == "v1.1.0")
        #expect(body["body"] as? String == "## 新しい機能")
        #expect(body["make_latest"] as? String == "true")
        #expect(body["draft"] as? Bool == false)

        // すでにあれば作らない（前の試行が作った後に落ちた）
        let existing = StubTransport([.json(200, created)])
        _ = try await Fixture.client(existing).publishRelease(tag: "v1.1.0", body: "## 新しい機能")
        #expect(existing.requests.map(\.httpMethod) == ["GET"])
    }

    // MARK: - 版を上げるコミット

    @Test func commitsFilesOnNewBranch() async throws {
        let commit = String(repeating: "e", count: 40)
        let transport = StubTransport([
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, #"{"sha":"\#(Self.tree)"}"#),
            .json(201, #"{"sha":"\#(commit)"}"#),
            .json(201, #"{"ref":"refs/heads/askhub/version-1.2.0","object":{"sha":"\#(commit)","type":"commit"}}"#)
        ])
        let head = try await Fixture.client(transport).commitFiles(FileCommit(
            files: ["Configs/Project.xcconfig": "MARKETING_VERSION = 1.2.0\n"],
            base: Fixture.sha,
            baseTree: Fixture.otherSHA,
            message: "[chore] MARKETING_VERSION を 1.2.0 に上げる",
            author: Self.takumi,
            date: Self.date,
            branch: "askhub/version-1.2.0"
        ))
        #expect(head == commit)
        let tree = Fixture.body(transport.requests[1])
        #expect(tree["base_tree"] as? String == Fixture.otherSHA)
        let entries = try #require(tree["tree"] as? [[String: String]])
        let entry = ["path": "Configs/Project.xcconfig", "mode": "100644", "type": "blob", "content": "MARKETING_VERSION = 1.2.0\n"]
        #expect(entries == [entry])
        let body = Fixture.body(transport.requests[2])
        #expect(body["parents"] as? [String] == [Fixture.sha])
        #expect(body["tree"] as? String == Self.tree)
        #expect((body["author"] as? [String: String])?["email"] == "1+mrs1669@users.noreply.github.com")
        #expect(Fixture.body(transport.requests[3])["ref"] as? String == "refs/heads/askhub/version-1.2.0")
    }

    @Test func reusesBranchMadeByPreviousAttempt() async throws {
        let branch = #"{"ref":"refs/heads/askhub/version-1.2.0","object":{"sha":"\#(Fixture.otherSHA)","type":"commit"}}"#
        let transport = StubTransport([.json(200, branch)])
        let request = FileCommit(
            files: ["Configs/Project.xcconfig": "x"],
            base: Fixture.sha,
            baseTree: Fixture.sha,
            message: "m",
            author: Self.takumi,
            date: Self.date,
            branch: "askhub/version-1.2.0"
        )
        let head = try await Fixture.client(transport).commitFiles(request)
        #expect(head == Fixture.otherSHA)
        #expect(transport.requests.count == 1)
    }
}
