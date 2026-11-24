@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 共通リポジトリ app-kit の様子（`app-kit.json`・`repo.json` の `appKit`・準備の入れ替え）と、広げる・やめるの意図
extension StateClientServiceTests {
    static let appKitOld = String(repeating: "a", count: 40)
    static let appKitNew = String(repeating: "b", count: 40)

    static func appKitFiles(rollout: String = "null", appKit: String? = nil, setup: String = "null") -> [String: String] {
        let installed = appKit ?? #"{"ref":"\#(appKitOld)","version":"v1.0.0","installedAt":"2027-01-10T00:00:00Z"}"#
        return askingEpic(extra: [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":\(installed),
             "protection":{},"setup":\(setup),"addedAt":"2026-11-01T00:00:00Z"}
            """,
            StatePath.appKit: """
            {"v":1,"checkedAt":"2027-01-15T07:00:00Z",
             "releases":[{"version":"v1.0.1","ref":"\(appKitNew)","changes":"- Upload の直し","foundAt":"2027-01-15T07:00:00Z"},
                         {"version":"v1.0.0","ref":"\(appKitOld)","foundAt":"2027-01-01T00:00:00Z"}],
             "adoption":{"version":"v1.0.0","ref":"\(appKitOld)"},"rollout":\(rollout),
             "templates":[{"repo":"shilokuma-inc/template-app-ios","appKit":null}]}
            """
        ])
    }

    static let failedRollout = """
        {"version":"v1.0.1","ref":"\(appKitNew)",
         "origin":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"},
         "state":"failed","pilot":"\(repo)","problem":"試しの 1 本で止めた",
         "targets":[{"repo":"\(repo)","kind":"repository","state":"failed","pullRequest":7,"head":"\(appKitNew)",
                     "problem":"待つチェック（build / build）が落ちた","updatedAt":"2027-01-15T07:30:00Z"}],
         "startedAt":"2027-01-15T07:10:00Z","updatedAt":"2027-01-15T07:30:00Z"}
        """

    @Test
    func buildsAppKitOverviewAndRepositoryVersion() async throws {
        let drift = #"{"foundAt":"2027-01-15T06:00:00Z","problems":[".swiftlint.yml が無い"]}"#
        let drifted = #"{"ref":"\#(Self.appKitOld)","version":"v1.0.0","drift":\#(drift)}"#
        let fixture = try makeService(files: Self.appKitFiles(appKit: drifted))
        let snapshot = try await fixture.service.fetchSnapshot()
        let appKit = try #require(snapshot.appKit)
        #expect(appKit.releases.map(\.version) == ["v1.0.1", "v1.0.0"])
        #expect(appKit.newRelease?.version == "v1.0.1")
        #expect(appKit.latest?.changes == "- Upload の直し")
        #expect(appKit.adoptionVersion == "v1.0.0")
        #expect(appKit.templates.map(\.repository) == ["shilokuma-inc/template-app-ios"])
        let installed = try #require(snapshot.repository(Self.repo)?.appKit?.installed)
        #expect(installed.versionLabel == "v1.0.0")
        #expect(installed.drift == [".swiftlint.yml が無い"])
        // 新しい版は時間のあるときに、ずれはリポジトリの出番として出す
        let items = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .appKit }
        #expect(Set(items.map(\.title)) == ["app-kit v1.0.1 を広げる", "app-kit のずれを直す"])
        #expect(items.allSatisfy { $0.urgency == .whenFree })
        // 2 行目は変更点の最初の 1 行を、箇条書きの記号を外して出す
        #expect(items.first { $0.title == "app-kit v1.0.1 を広げる" }?.detail == "Upload の直し")
    }

    /// 一覧の 2 行目に出す変更点は、Markdown の記号を外した最初の 1 行
    @Test
    func summarizesChangesAsPlainText() {
        #expect(AppKitOverview.plainSummary(of: "- macOS の Archive・`.pkg` の書き出し\n- **Upload** を扱う") == "macOS の Archive・.pkg の書き出し")
        #expect(AppKitOverview.plainSummary(of: "\n## 変更点\n1. 直した") == "変更点")
        #expect(AppKitOverview.plainSummary(of: "2. 直した") == "直した")
        #expect(AppKitOverview.plainSummary(of: " \n- \n") == nil)
        // 記号の後ろに空白が無いもの（負の符号）は残し、1 文字の強調も外す。語の途中の記号は残す
        #expect(AppKitOverview.plainSummary(of: "- -1 を返す場合の処理を修正") == "-1 を返す場合の処理を修正")
        #expect(AppKitOverview.plainSummary(of: "- 認証の *再試行* と _待ち_ を直す") == "認証の 再試行 と 待ち を直す")
        #expect(AppKitOverview.plainSummary(of: "- `snake_case` と a*b はそのまま") == "snake_case と a*b はそのまま")
    }

    /// 広げる途中で止まったら、進行が止まっていますに出し、同じ版のもう一度試すとやめるを送れる。ほかの版は広げられない
    @Test
    func failedRolloutIsBlockingAndCanBeRetriedOrStopped() async throws {
        let fixture = try makeService(files: Self.appKitFiles(rollout: Self.failedRollout))
        let snapshot = try await fixture.service.fetchSnapshot()
        let rollout = try #require(snapshot.appKit?.rollout)
        #expect(rollout.state == .failed)
        #expect(rollout.targets.first?.pullRequestURL?.absoluteString == "https://github.com/\(Self.repo)/pull/7")
        #expect(snapshot.repository(Self.repo)?.appKit?.rolloutTarget?.state == .failed)
        let blocking = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .appKit && $0.urgency == .blocking }
        #expect(blocking.map(\.title) == ["app-kit v1.0.1 を広げる途中で止まりました"])
        #expect(blocking.first?.route == .appKit)
        #expect(fixture.service.supports(.rolloutAppKit(version: "v1.0.1", ref: Self.appKitNew)))
        #expect(fixture.service.supports(.stopAppKitRollout(version: "v1.0.1", ref: Self.appKitNew)))
        #expect(!fixture.service.supports(.rolloutAppKit(version: "v1.0.0", ref: Self.appKitOld)))
        // 見たときと違うコミットは送らない
        #expect(!fixture.service.supports(.rolloutAppKit(version: "v1.0.1", ref: Self.appKitOld)))
    }

    /// 広げるは、封筒に repo を書かず、版のタグとコミットに結びつけて送る
    @Test
    func rolloutIsSentBoundToReleaseCommit() async throws {
        let fixture = try makeService(files: Self.appKitFiles())
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.rolloutAppKit(version: "v1.0.1", ref: Self.appKitNew))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.repo == nil)
        let rollout = try RolloutAppKitIntent(envelope: envelope)
        #expect(rollout.release.version.rawValue == "v1.0.1")
        #expect(rollout.release.ref == Self.appKitNew)
        #expect(HumanIntent.rolloutAppKit(version: "v1.0.1", ref: Self.appKitNew).targets == [.appKit])
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.stopAppKitRollout(version: "v1.0.1", ref: Self.appKitNew))
        }
    }

    /// app-kit に入れ替える準備の PR は、入れる版と名前が変わるチェックを出す
    @Test
    func setupShowsAppKitAdoption() async throws {
        let setup = """
            {"updatedAt":"2027-01-15T07:00:00Z","discussions":"ready",
             "workflows":{"state":"open","pullRequest":12,"head":"\(Self.setupHead)",
                          "changes":[{"kind":"adoptAppKit","path":".github/app-kit.json"},
                                     {"kind":"removeReplaced","path":".github/workflows/build-develop.yml","lines":120,
                                      "steps":["Firebase の設定"]}],
                          "appKit":{"version":"v1.0.1","ref":"\(Self.appKitNew)","renamedChecks":[{"from":"Build","to":"build / build"}]}}}
            """
        let fixture = try makeService(files: Self.appKitFiles(appKit: "null", setup: setup))
        let pullRequest = try #require(try await fixture.service.fetchSnapshot().repository(Self.repo)?.setup?.workflowPullRequest)
        #expect(pullRequest.appKit == SetupAppKit(version: "v1.0.1", renamedChecks: ["Build → build / build"]))
        #expect(pullRequest.changes == [
            "app-kit.json を app-kit の中身にする",
            "build-develop.yml を外す（app-kit に置き換わる・120 行）。app-kit に無い手順: Firebase の設定"
        ])
        #expect(RepositorySetupSection.approvalMessage(pullRequest).contains("Build → build / build"))
    }
}
