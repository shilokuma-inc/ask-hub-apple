@testable import AskHubKit
import Foundation
import Testing

struct GitHubReleaseReaderTests {
    private let sleeper = SleepRecorder()
    private let version = ReleaseVersion(major: 1, minor: 1, patch: 0)

    private func makeReader(_ http: MockHTTPClient) -> GitHubReleaseReader {
        let sleeper = sleeper
        let client = GitHubClient(
            token: "github_pat_secret",
            http: http,
            sleep: { sleeper.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        return GitHubReleaseReader(client: client)
    }

    /// Contents API の応答（GitHub と同じく、base64 を 60 文字ごとに改行する）
    private static func file(_ text: String) -> MockHTTPClient.Response {
        let base64 = Data(text.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let escaped = base64.replacingOccurrences(of: "\n", with: "\\n")
        return .init(status: 200, body: #"{ "type": "file", "encoding": "base64", "size": \#(text.utf8.count), "content": "\#(escaped)" }"#)
    }

    private static let notFound = MockHTTPClient.Response(status: 404, body: #"{ "message": "Not Found" }"#)

    private static func refJSON(_ ref: String, sha: String, type: String = "commit") -> String {
        #"{ "ref": "\#(ref)", "node_id": "x", "url": "https://api.github.com/x", "object": { "sha": "\#(sha)", "type": "\#(type)", "url": "https://api.github.com/y" } }"#
    }

    private static func refsJSON(_ refs: String...) -> String {
        "[" + refs.joined(separator: ",") + "]"
    }

    private static func ref(_ request: URLRequest) -> String? {
        guard let url = request.url else {
            return nil
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ref" }?.value
    }

    // MARK: - release ブランチとタグ

    @Test func readsReleaseBranchesAndTagsFollowingPages() async throws {
        let next = #"<https://api.github.com/repositories/1/git/matching-refs/heads/release/?per_page=100&page=2>; rel="next""#
        let http = MockHTTPClient([
            .init(status: 200, body: "[\(Self.refJSON("refs/heads/release/1.0.0", sha: "b1"))]", headers: ["Link": next]),
            .init(
                status: 200,
                body: Self.refsJSON(Self.refJSON("refs/heads/release/1.1.0", sha: "b2"), Self.refJSON("refs/heads/release/foo", sha: "b3"))
            ),
            .init(
                status: 200,
                body: Self.refsJSON(Self.refJSON("refs/tags/v1.0.0", sha: "t1", type: "tag"), Self.refJSON("refs/tags/very-old", sha: "t2"))
            )
        ])
        let refs = try await makeReader(http).refs(repository: "o/r")

        #expect(refs.branches == [
            ReleaseRef(name: "release/1.0.0", sha: "b1", version: ReleaseVersion("1.0.0")),
            ReleaseRef(name: "release/1.1.0", sha: "b2", version: ReleaseVersion("1.1.0")),
            ReleaseRef(name: "release/foo", sha: "b3", version: nil)
        ])
        #expect(refs.tags == [
            ReleaseRef(name: "v1.0.0", sha: "t1", version: ReleaseVersion("1.0.0")),
            ReleaseRef(name: "very-old", sha: "t2", version: nil)
        ])
        #expect(refs.unreleasedVersions == [version])

        #expect(http.requests.count == 3)
        #expect(http.requests[0].url?.path() == "/repos/o/r/git/matching-refs/heads/release/")
        #expect(http.requests[1].url?.absoluteString.contains("page=2") == true)
        #expect(http.requests[2].url?.path() == "/repos/o/r/git/matching-refs/tags/v")
    }

    @Test func treatsEmptyRepositoryAsNoRefs() async throws {
        let http = MockHTTPClient([
            .init(status: 409, body: #"{ "message": "Git Repository is empty." }"#),
            .init(status: 409, body: #"{ "message": "Git Repository is empty." }"#)
        ])
        let refs = try await makeReader(http).refs(repository: "o/r")
        #expect(refs == ReleaseRefs(branches: [], tags: []))
    }

    @Test func refsDistinguishErrors() async {
        await #expect(throws: ReleaseReadError.repositoryNotFound) {
            try await makeReader(MockHTTPClient([Self.notFound])).refs(repository: "o/r")
        }
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: ReleaseReadError.permissionDenied) {
            try await makeReader(denied).refs(repository: "o/r")
        }
        let limited = MockHTTPClient([.init(status: 403, body: "{}", headers: ["Retry-After": "3600"])])
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(3600))) {
            try await makeReader(limited).refs(repository: "o/r")
        }
    }

    // MARK: - MARKETING_VERSION

    @Test func readsMarketingVersionOnDevelop() async throws {
        let http = MockHTTPClient([Self.file("// バージョン\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n")])
        let marketing = try await makeReader(http).marketingVersion(repository: "o/r")
        #expect(marketing.version == ReleaseVersion("1.0.0"))
        #expect(marketing.nextMinor == version)

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/repos/o/r/contents/Configs/Project.xcconfig")
        #expect(Self.ref(request) == "develop")
    }

    @Test func marketingVersionDistinguishesErrors() async {
        await #expect(throws: ReleaseReadError.fileNotFound(path: "Configs/Project.xcconfig", ref: "main")) {
            try await makeReader(MockHTTPClient([Self.notFound])).marketingVersion(repository: "o/r", ref: "main")
        }
        await #expect(throws: ReleaseReadError.marketingVersionNotFound) {
            try await makeReader(MockHTTPClient([Self.file("CURRENT_PROJECT_VERSION = 1\n")])).marketingVersion(repository: "o/r")
        }
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: ReleaseReadError.permissionDenied) {
            try await makeReader(denied).marketingVersion(repository: "o/r")
        }
        // ディレクトリ（配列）・1 MB を超えて本文が返らないファイルは読めない
        let directory = MockHTTPClient([.init(status: 200, body: "[]")])
        await #expect(throws: ReleaseReadError.invalidContent(path: "Configs/Project.xcconfig")) {
            try await makeReader(directory).marketingVersion(repository: "o/r")
        }
        let large = MockHTTPClient([.init(status: 200, body: #"{ "type": "file", "encoding": "none", "content": "" }"#)])
        await #expect(throws: ReleaseReadError.invalidContent(path: "Configs/Project.xcconfig")) {
            try await makeReader(large).marketingVersion(repository: "o/r")
        }
    }

    // MARK: - 下書きと確定

    @Test func readsDraftOnReleaseBranch() async throws {
        let http = MockHTTPClient([Self.file(WhatsNewDraftTests.draftJSON)])
        let draft = try #require(try await makeReader(http).whatsNewDraft(repository: "o/r", version: version))
        #expect(draft.version == "1.1.0")
        let request = try #require(http.requests.first)
        #expect(request.url?.path() == "/repos/o/r/contents/AppStore/whats-new-draft.json")
        #expect(Self.ref(request) == "release/1.1.0")
    }

    @Test func missingDraftIsNil() async throws {
        #expect(try await makeReader(MockHTTPClient([Self.notFound])).whatsNewDraft(repository: "o/r", version: version) == nil)
    }

    private static let languagesJSON = #"""
        { "_comment": ["…"], "languages": [
          { "language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja" },
          { "language": "en-US", "appleLanguage": "en", "appleLocale": "en_US", "storeLocale": "en-US" },
          { "language": "../secret", "appleLanguage": "x", "appleLocale": "x", "storeLocale": "x" },
          { "language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja" }
        ] }
        """#

    @Test func reportsDraftEvenWhenMetadataIsConfirmed() async throws {
        let http = MockHTTPClient([
            Self.file(Self.languagesJSON),
            Self.file(#"{ "description": "…", "whatsNew": {"version": "1.0.0", "text": "前のもの"} }"#),
            Self.notFound,
            Self.file(WhatsNewDraftTests.draftJSON)
        ])
        let notes = try await makeReader(http).releaseNotes(repository: "o/r", version: version)

        guard case .draft(let draft) = notes.status else {
            Issue.record("下書きがあるのに \(notes.status)")
            return
        }
        #expect(draft.pullRequests.count == 3)
        // パスに使えない言語コードは読まない。重複も 1 つにする
        #expect(notes.languages == ["ja", "en-US"])
        #expect(notes.whatsNew == ["ja": ConfirmedWhatsNew(version: "1.0.0", text: "前のもの")])
        #expect(notes.confirmedTexts.isEmpty)
        #expect(http.requests.compactMap { $0.url?.path() } == [
            "/repos/o/r/contents/AppStore/languages.json",
            "/repos/o/r/contents/AppStore/metadata/ja.json",
            "/repos/o/r/contents/AppStore/metadata/en-US.json",
            "/repos/o/r/contents/AppStore/whats-new-draft.json"
        ])
        #expect(http.requests.allSatisfy { Self.ref($0) == "release/1.1.0" })
    }

    @Test func reportsConfirmedWhenEveryLanguageHasTheVersion() async throws {
        let http = MockHTTPClient([
            Self.file(#"{ "languages": [{ "language": "ja" }] }"#),
            Self.file(#"{ "whatsNew": {"version": "1.1.0", "text": "・直した"} }"#),
            Self.notFound
        ])
        let notes = try await makeReader(http).releaseNotes(repository: "o/r", version: version)
        #expect(notes.status == .confirmed)
        #expect(notes.confirmedTexts == ["ja": "・直した"])
    }

    @Test func reportsMissingWithoutDraftOrConfirmedNotes() async throws {
        // whatsNew が無い・前の形（文字列）のときは確定していないものとする
        let http = MockHTTPClient([
            Self.file(#"{ "languages": [{ "language": "ja" }, { "language": "en" }] }"#),
            Self.file(#"{ "whatsNew": "前の形" }"#),
            Self.file(#"{ "description": "…" }"#),
            Self.notFound
        ])
        let notes = try await makeReader(http).releaseNotes(repository: "o/r", version: version)
        #expect(notes.status == .missing)
        #expect(notes.whatsNew.isEmpty)

        // release ブランチが無ければどのファイルも 404 になり、何も無いものとして返す
        let gone = MockHTTPClient([Self.notFound, Self.notFound])
        let goneNotes = try await makeReader(gone).releaseNotes(repository: "o/r", version: version)
        #expect(goneNotes.status == .missing)
        #expect(goneNotes.languages.isEmpty)
    }

    @Test func reportsUnsupportedDraftWithoutThrowing() async throws {
        let http = MockHTTPClient([
            Self.file(#"{ "languages": [{ "language": "ja" }] }"#),
            Self.file(#"{ "whatsNew": {"version": "1.1.0", "text": "・直した"} }"#),
            Self.file(#"{ "schemaVersion": 2 }"#)
        ])
        let notes = try await makeReader(http).releaseNotes(repository: "o/r", version: version)
        #expect(notes.status == .unsupportedDraft(schemaVersion: 2))
        #expect(notes.confirmedTexts == ["ja": "・直した"])

        let direct = MockHTTPClient([Self.file(#"{ "schemaVersion": 2 }"#)])
        await #expect(throws: ReleaseReadError.unsupportedDraftSchema(2)) {
            try await makeReader(direct).whatsNewDraft(repository: "o/r", version: version)
        }
    }

    @Test func releaseNotesReportInvalidFilesAndPermission() async {
        let brokenLanguages = MockHTTPClient([Self.file("not json")])
        await #expect(throws: ReleaseReadError.invalidContent(path: "AppStore/languages.json")) {
            try await makeReader(brokenLanguages).releaseNotes(repository: "o/r", version: version)
        }
        let brokenMetadata = MockHTTPClient([Self.file(#"{ "languages": [{ "language": "ja" }] }"#), Self.file("not json")])
        await #expect(throws: ReleaseReadError.invalidContent(path: "AppStore/metadata/ja.json")) {
            try await makeReader(brokenMetadata).releaseNotes(repository: "o/r", version: version)
        }
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: ReleaseReadError.permissionDenied) {
            try await makeReader(denied).releaseNotes(repository: "o/r", version: version)
        }
        #expect(sleeper.recorded.isEmpty)
    }
}
