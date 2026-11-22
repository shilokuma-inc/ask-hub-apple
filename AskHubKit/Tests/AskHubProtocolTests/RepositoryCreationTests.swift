@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let creationKinds: [Kind] = [
        Kind(vectors: "payloads/createRepository.json", kind: "createRepository", target: nil, targetVersion: nil) {
            try CreateRepositoryIntent(envelope: $0).payload
        }
    ]
}

/// テンプレートから作る人の意図（`createRepository`）と、`repo.json` の `created`
struct RepositoryCreationTests {
    private func envelope(repo: String? = "shilokuma-inc/askhub-create-check", target: IntentEnvelope.Target? = nil) -> IntentEnvelope {
        IntentEnvelope(
            kind: CreateRepositoryIntent.kind,
            repo: repo.flatMap(RepositoryFullName.init(rawValue:)),
            target: target,
            targetVersion: nil,
            payload: [
                "template": .string("visionos"),
                "visibility": .string("private"),
                "appName": .string("CreateCheck"),
                "bundleId": .string("jp.shilokuma.CreateCheck")
            ],
            issuedAt: Timestamp(rawValue: "2026-11-22T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsTemplateVisibilityAndNames() throws {
        let intent = try CreateRepositoryIntent(envelope: envelope())
        #expect(intent.repo.rawValue == "shilokuma-inc/askhub-create-check")
        #expect(intent.template == .visionos)
        #expect(intent.template.repository.rawValue == "shilokuma-vision/template-app-visionos")
        #expect(intent.visibility == .private)
        #expect(intent.appName == "CreateCheck")
        #expect(intent.bundleId == "jp.shilokuma.CreateCheck")
    }

    @Test func refusesMissingRepositoryAndTarget() {
        #expect(throws: MalformedIntent.self) { try CreateRepositoryIntent(envelope: envelope(repo: nil)) }
        #expect(throws: MalformedIntent.self) {
            try CreateRepositoryIntent(envelope: envelope(target: .init(type: "epic", epic: EpicIntentsTests.epic)))
        }
    }

    @Test(arguments: ["Memo", "A", "Memo2", String(repeating: "a", count: 60)])
    func acceptsAppNames(_ name: String) {
        #expect(CreateRepositoryIntent.isAppName(name))
    }

    @Test(arguments: ["", "2Memo", "memo-app", "メモ", "Memo App", String(repeating: "a", count: 61)])
    func refusesAppNames(_ name: String) {
        #expect(!CreateRepositoryIntent.isAppName(name))
    }

    @Test func bundleIdRules() {
        #expect(CreateRepositoryIntent.isBundleId("jp.shilokuma.CreateCheck"))
        #expect(CreateRepositoryIntent.isBundleId("com.example.my-app"))
        #expect(!CreateRepositoryIntent.isBundleId("CreateCheck"))
        #expect(!CreateRepositoryIntent.isBundleId("jp..CreateCheck"))
        #expect(!CreateRepositoryIntent.isBundleId("jp.shilokuma.Create_Check"))
        #expect(CreateRepositoryIntent.defaultBundleId(appName: "Memo") == "jp.shilokuma.Memo")
    }

    /// 作った後に入れるビルドの設定は、テンプレートのプロジェクト・スキームの名前と Build のチェックに合う
    @Test func templateBuildSettings() throws {
        let ios = try RepositoryTemplate.ios.build(appName: "CreateCheck")
        #expect(ios.xcode.project == "CreateCheck.xcodeproj")
        #expect(ios.xcode.scheme == "CreateCheck")
        #expect(ios.xcode.destinations == [.simulator(.init(platform: .iOS, deviceType: "iPhone 17 Pro"))])
        #expect(ios.xcode.testLight.onlyTesting == ["CreateCheckTests"])
        #expect(ios.childChecks == ["build / build"])
        #expect(ios.problems.isEmpty)
        let vision = try RepositoryTemplate.visionos.build(appName: "CreateCheck")
        #expect(vision.xcode.destinations == [.simulator(.init(platform: .visionOS, deviceType: "Apple Vision Pro"))])
    }
}
