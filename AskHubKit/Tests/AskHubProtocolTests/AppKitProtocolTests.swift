@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let appKitTarget = IntentEnvelope.Target(type: "appKitRelease", id: "v1.1.0")
    /// app-kit の版の意図は封筒に repo を持たないので、例を読むときは repo を外して読む
    static let appKitKinds: [Kind] = [
        Kind(vectors: "payloads/rolloutAppKit.json", kind: "rolloutAppKit", target: appKitTarget, targetVersion: head) {
            _ = try RolloutAppKitIntent(envelope: CleanupIntentsTests.withoutRepository($0))
            return [:]
        },
        Kind(vectors: "payloads/stopAppKitRollout.json", kind: "stopAppKitRollout", target: appKitTarget, targetVersion: head) {
            _ = try StopAppKitRolloutIntent(envelope: CleanupIntentsTests.withoutRepository($0))
            return [:]
        }
    ]
}

/// app-kit の版（`app-kit.json`・`repo.json` の `appKit`・準備の `adoptAppKit`）と、版を広げる・やめる人の意図
struct AppKitProtocolTests {
    static let commit = "0123456789abcdef0123456789abcdef01234567"
    static let next = "89abcdef0123456789abcdef0123456789abcdef"

    private func envelope(
        kind: String,
        repo: RepositoryFullName? = nil,
        target: IntentEnvelope.Target? = .init(type: "appKitRelease", id: "v1.1.0"),
        targetVersion: String? = Self.next,
        payload: [String: JSONValue] = [:]
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: repo,
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-25T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func read<File: StateFile>(_ type: File.Type, _ vectors: String, case name: String) throws -> File {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data(vectors)) as? [String: Any])
        let cases = try #require(file["cases"] as? [[String: Any]])
        let value = try #require(cases.first { $0["name"] as? String == name }?["value"], "\(name)")
        return try StateFileCoder.decode(File.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test(arguments: ["v1.0.0", "v0.0.1", "v10.20.300", "v9999.0.0"])
    func readsVersions(_ text: String) throws {
        let version = try #require(AppKitVersion(rawValue: text))
        #expect(version.rawValue == text)
        #expect(AppKitPolicy.branch(for: version) == "askhub/app-kit-\(text)")
        #expect(EpicFile.isBranchName(AppKitPolicy.branch(for: version)))
    }

    @Test(arguments: ["1.0.0", "v1.0", "v1.0.0.0", "v01.0.0", "v1.0.0-beta", "v10000.0.0", "V1.0.0", "v1..0", "v-1.0.0", ""])
    func refusesMalformedVersions(_ text: String) {
        #expect(AppKitVersion(rawValue: text) == nil)
    }

    @Test func comparesVersionsByNumber() throws {
        let versions = try ["v1.10.0", "v1.2.0", "v2.0.0", "v1.2.10", "v1.2.9"].map { try #require(AppKitVersion(rawValue: $0)) }
        #expect(versions.sorted().map(\.rawValue) == ["v1.2.0", "v1.2.9", "v1.2.10", "v1.10.0", "v2.0.0"])
        #expect(versions[2].major == 2 && versions[3].patch == 10)
    }

    @Test func templatesAreTheCreationTemplates() {
        #expect(AppKitPolicy.templates.map(\.rawValue) == ["shilokuma-inc/template-app-ios", "shilokuma-vision/template-app-visionos"])
        #expect(AppKitPolicy.repository.rawValue == "shilokuma-inc/app-kit")
        #expect(AppKitPolicy.defaultPilot.rawValue == "tm-family/shinkeisuijaku-app-ios")
        #expect(StatePath.appKit == "app-kit.json")
    }

    /// 書き直して読み直すだけでは、読み落とした欄に気づけないので、読んだ値を直接確かめる
    @Test func readsReleasesRolloutAndTemplates() throws {
        let file = try read(AppKitFile.self, "state/app-kit.json", case: "full")
        #expect(file.checkedAt?.rawValue == "2026-11-25T10:00:00Z")
        #expect(file.latest?.version.rawValue == "v1.1.0")
        #expect(file.latest?.changes == "- visionOS のスクショを撮れるようにした\n- Upload の内部テスターの直し")
        #expect(file.release(AppKitVersion(rawValue: "v1.0.0")!)?.ref == Self.commit)
        #expect(file.adoption == .init(version: AppKitVersion(rawValue: "v1.0.0")!, ref: Self.commit))
        let rollout = try #require(file.rollout)
        #expect(rollout.state == .running)
        #expect(rollout.pilot.rawValue == "tm-family/shinkeisuijaku-app-ios")
        #expect(rollout.origin.nonce.rawValue == "01JCN0NCE00000000000000001")
        #expect(rollout.targets.map(\.state) == [.done, .skipped, .open])
        let kobosu = try #require(rollout.target(RepositoryFullName(rawValue: "tm-family/kobosu-app-ios")!))
        #expect(kobosu.pullRequest == 51 && kobosu.head == Self.commit && kobosu.kind == .repository)
        #expect(rollout.targets[1].problem == "まだ app-kit に入れ替えていない（準備をやり直して入れる）")
        #expect(file.templates.map(\.appKit?.version?.rawValue) == ["v1.0.0", nil])
        #expect(file.templates[0].appKit?.installedAt?.rawValue == "2026-11-23T09:00:00Z")
        let failed = try read(AppKitFile.self, "state/app-kit.json", case: "rollout-failed").rollout
        #expect(failed?.state == .failed)
        #expect(failed?.problem == "試しの 1 本 tm-family/shinkeisuijaku-app-ios の develop の Build が落ちた")
    }

    @Test func readsInstalledAppKitAndAdoption() throws {
        let appKit = try #require(try read(RepositoryFile.self, "state/repo.json", case: "app-kit-installed").appKit)
        #expect(appKit.ref == Self.commit)
        #expect(appKit.version?.rawValue == "v1.0.0")
        #expect(appKit.installedAt?.rawValue == "2026-11-23T10:00:00Z")
        #expect(appKit.drift?.problems == [".github/workflows/build.yml が app-kit v1.0.0 の中身と違う"])
        let workflows = try #require(try read(RepositoryFile.self, "state/repo.json", case: "setup-adopt-app-kit").setup?.workflows)
        #expect(workflows.appKit?.version.rawValue == "v1.0.0")
        #expect(workflows.appKit?.ref == Self.commit)
        #expect(workflows.appKit?.renamedChecks == [CheckRename(from: "Build", to: "build / build")])
        #expect(workflows.changes.map(\.kind) == [.adoptAppKit, .adoptAppKit, .removeReplaced, .removeReplaced])
        #expect(workflows.changes[2].lines == 120)
        #expect(workflows.changes[2].steps == ["Firebase の設定を書き出す"])
        #expect(workflows.changes[3].steps == nil)
    }

    @Test func readsReleaseTargetOfBothIntents() throws {
        let rollout = try RolloutAppKitIntent(envelope: envelope(kind: RolloutAppKitIntent.kind))
        #expect(rollout.release.version.rawValue == "v1.1.0")
        #expect(rollout.release.ref == Self.next)
        #expect(rollout.release.target == .init(type: "appKitRelease", id: "v1.1.0"))
        #expect(rollout.intent.nonce.rawValue == "01JCN0NCE00000000000000001")
        let stop = try StopAppKitRolloutIntent(envelope: envelope(kind: StopAppKitRolloutIntent.kind))
        #expect(stop.release == rollout.release)
        // 種類を取り違えない
        #expect(throws: MalformedIntent.self) { try StopAppKitRolloutIntent(envelope: envelope(kind: RolloutAppKitIntent.kind)) }
        #expect(throws: MalformedIntent.self) { try RolloutAppKitIntent(envelope: envelope(kind: StopAppKitRolloutIntent.kind)) }
    }

    /// 版の意図はリポジトリに結びつかず、版のタグとコミットに結びつく（ブランチの名前・短い SHA・別の対象は読まない）
    @Test func refusesWrongEnvelope() {
        let repo = RepositoryFullName(rawValue: "tm-family/kobosu-app-ios")
        let wrong: [IntentEnvelope] = [
            envelope(kind: RolloutAppKitIntent.kind, repo: repo),
            envelope(kind: RolloutAppKitIntent.kind, target: nil),
            envelope(kind: RolloutAppKitIntent.kind, target: .init(type: "appKitRelease", id: "1.1.0")),
            envelope(kind: RolloutAppKitIntent.kind, target: .init(type: "appKitRelease")),
            envelope(kind: RolloutAppKitIntent.kind, target: .init(type: "setupPullRequest", id: "v1.1.0")),
            envelope(kind: RolloutAppKitIntent.kind, target: .init(type: "appKitRelease", epic: EpicIntentsTests.epic, id: "v1.1.0")),
            envelope(kind: RolloutAppKitIntent.kind, targetVersion: nil),
            envelope(kind: RolloutAppKitIntent.kind, targetVersion: "v1.1.0"),
            envelope(kind: RolloutAppKitIntent.kind, targetVersion: String(Self.next.prefix(7))),
            envelope(kind: RolloutAppKitIntent.kind, payload: ["force": .bool(true)])
        ]
        for item in wrong {
            #expect(throws: MalformedIntent.self) { try RolloutAppKitIntent(envelope: item) }
        }
    }

    /// 型だけでは表せない決まり: 準備の adoptAppKit と入れる版は一緒に書く・付け替えは名前が変わる
    @Test func setupAdoptionChecksRelations() throws {
        let version = try #require(AppKitVersion(rawValue: "v1.0.0"))
        let adopt = WorkflowChange(kind: .adoptAppKit, path: ".github/app-kit.json")
        let adoption = AppKitAdoption(version: version, ref: Self.commit)
        let good = WorkflowSetup(state: .open, pullRequest: 1, head: Self.commit, changes: [adopt], appKit: adoption)
        #expect(good.violations.isEmpty)
        #expect(!WorkflowSetup(state: .open, pullRequest: 1, head: Self.commit, changes: [adopt]).violations.isEmpty)
        var renamed = good
        renamed.appKit?.renamedChecks = []
        #expect(!renamed.violations.isEmpty)
        renamed.appKit?.renamedChecks = [.init(from: "build", to: "build / build")]
        #expect(renamed.violations.isEmpty)
        renamed.appKit?.ref = "v1.0.0"
        #expect(!renamed.violations.isEmpty)
    }
}
