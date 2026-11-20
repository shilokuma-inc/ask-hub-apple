@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// リポジトリの保護（`repo.json` の `protection`）と、加えるときの準備（`setup`）の様子・人がすること・送る意図
extension StateClientServiceTests {
    static let setupHead = String(repeating: "c", count: 40)

    static func administeredRepository(protection: String, setup: String = "null", build: String = "null") -> [String: String] {
        askingEpic(extra: [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":null,"build":\(build),
             "protection":\(protection),"setup":\(setup),"addedAt":"2026-11-01T00:00:00Z"}
            """
        ])
    }

    static let openSetup = """
        {"updatedAt":"2027-01-15T07:00:00Z","discussions":"missingCategory",
         "workflows":{"state":"open","pullRequest":12,"head":"\(setupHead)",
                      "changes":[{"kind":"removePathFilters","path":".github/workflows/build.yml"},
                                 {"kind":"removeLegacy","path":".github/workflows/close-goal-discussion.yml"}]}}
        """

    @Test
    func buildsProtectionAndSetupFromRepositoryFile() async throws {
        let protection = """
            {"appliedAt":"2027-01-10T00:00:00Z","requiredChecks":["build / build"],"rulesetId":10,
             "replaced":[{"kind":"classic","name":"develop"}],"remaining":[{"kind":"organizationRuleset","name":"org"}],
             "drift":{"foundAt":"2027-01-15T06:00:00Z","problems":["必須のチェックが変わった（今は 無し）"]}}
            """
        let fixture = try makeService(files: Self.administeredRepository(protection: protection, setup: Self.openSetup))
        let snapshot = try await fixture.service.fetchSnapshot()
        let repository = try #require(snapshot.repository(Self.repo))
        let shown = try #require(repository.protection)
        #expect(shown.requiredChecks == ["build / build"])
        #expect(shown.replaced == ["クラシックの保護 develop"])
        #expect(shown.remaining == ["organization のルールセット org"])
        guard case let .drifted(_, problems, _) = shown.state else {
            Issue.record("ずれが出ていない: \(shown.state)")
            return
        }
        #expect(problems == ["必須のチェックが変わった（今は 無し）"])
        let setup = try #require(repository.setup)
        #expect(setup.discussions == .missingCategory)
        #expect(setup.workflowPullRequest == .init(
            number: 12, head: Self.setupHead, state: .open, changes: ["build.yml の paths を外す", "close-goal-discussion.yml を外す"]
        ))
        // 保護のずれ・Ideas を作る・ワークフローの直しを承認する を、時間のあるときに出す
        let items = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .repositorySetup }
        #expect(Set(items.map(\.title)) == ["保護のずれを直す", "Discussions のカテゴリを作る", "ワークフローの直しを承認する"])
        #expect(items.allSatisfy { $0.urgency == .whenFree && $0.route == .repository(Self.repo) })
    }

    /// まだ掛けていなければ、押す画面の既定の必須のチェックは、ビルドの設定の子 PR で待つチェック
    @Test
    func defaultRequiredChecksComeFromBuildSettings() async throws {
        let build = """
            {"xcode":{"project":"App.xcodeproj","scheme":"App","destinations":[{"platform":"macOS"}]},
             "childChecks":["ci / unit"],"finalChecks":["ci / unit","ci / ui"]}
            """
        let fixture = try makeService(files: Self.administeredRepository(protection: #"{"appliedAt":null}"#, build: build))
        let repository = try #require(try await fixture.service.fetchSnapshot().repository(Self.repo))
        #expect(repository.protection?.state == .notApplied)
        #expect(repository.protection?.requiredChecks == ["ci / unit"])
        #expect(repository.setup == nil)
        // ビルドの設定も無ければ build / build
        let plain = try makeService(files: Self.administeredRepository(protection: #"{"appliedAt":null}"#))
        #expect(try await plain.service.fetchSnapshot().repository(Self.repo)?.protection?.requiredChecks == ["build / build"])
    }

    /// 保護の設定は直した必須のチェックで送り、断られたら理由を保護の欄に出す
    @Test
    func applyProtectionIsSentAndRejectionIsShown() async throws {
        let fixture = try makeService(files: Self.administeredRepository(protection: #"{"appliedAt":null}"#))
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.applyProtection(repositoryID: Self.repo, requiredChecks: ["build / build", "lint"]))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == ApplyProtectionIntent.kind)
        #expect(envelope.repo?.rawValue == Self.repo)
        #expect(try ApplyProtectionIntent(envelope: envelope).requiredChecks == ["build / build", "lint"])

        let reason = "example/sample-ios は private のリポジトリで、今のプランではルールセットを掛けられない"
        let consumed = #"{"v":1,"kind":"applyProtection","consumedAt":"2027-01-15T08:00:00Z","result":"rejected","reason":"\#(reason)"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))
        #expect(try await fixture.service.fetchSnapshot().repository(Self.repo)?.protection?.rejection == reason)
    }

    /// 送れない必須のチェックは、送る前に止める
    @Test
    func malformedRequiredChecksAreNotSent() async throws {
        let fixture = try makeService(files: Self.administeredRepository(protection: #"{"appliedAt":null}"#))
        _ = try await fixture.service.fetchSnapshot()
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.applyProtection(repositoryID: Self.repo, requiredChecks: []))
        }
        #expect(ProtectionSheet.checks(from: " build / build \n\nlint\nbuild / build") == ["build / build", "lint"])
    }

    /// 準備の PR の承認は、見たときの head に結びつけて送る
    @Test
    func setupApprovalIsBoundToSeenHead() async throws {
        let fixture = try makeService(files: Self.administeredRepository(protection: #"{"appliedAt":null}"#, setup: Self.openSetup))
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.approveSetup(repositoryID: Self.repo, pullRequest: 12, head: Self.setupHead))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let approval = try ApproveSetupPullRequestIntent(envelope: envelope)
        #expect(approval.pullRequest == 12)
        #expect(approval.head == Self.setupHead)
        let intent = HumanIntent.approveSetup(repositoryID: Self.repo, pullRequest: 12, head: Self.setupHead)
        #expect(intent.targets == [.repository(Self.repo)])
    }

    /// 準備の依頼の下書きは、ワークフローには触れないよう添えて、そのリポジトリに出す
    @Test
    func preparationRequestDraftTargetsRepository() throws {
        let repository = try #require(DemoData.repositories.first)
        let draft = RepositorySetupSection.preparationRequest(for: repository)
        #expect(draft.repositoryID == repository.id)
        #expect(draft.body.contains("ワークフローのファイル（.github/workflows/）は、ワーカーが変えられないので触れないでください"))
    }
}
