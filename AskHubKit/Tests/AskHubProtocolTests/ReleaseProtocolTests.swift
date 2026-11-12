@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let releaseTarget = IntentEnvelope.Target(type: "release", id: "1.1.0")
    static let releaseKinds: [Kind] = [
        Kind(vectors: "payloads/publishGitHubRelease.json", kind: "publishGitHubRelease", target: releaseTarget, targetVersion: "2") {
            try PublishGitHubReleaseIntent(envelope: $0).payload
        }
    ]
}

/// App Store で配信した版の記録（`releases/<版>.json`）と、リリース文の公開の人の意図
struct ReleaseProtocolTests {
    private func envelope(
        target: IntentEnvelope.Target?,
        targetVersion: String?,
        repo: String? = "shariverse/oshikatsu-countdown-ios"
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: PublishGitHubReleaseIntent.kind,
            repo: repo.flatMap(RepositoryFullName.init(rawValue:)),
            target: target,
            targetVersion: targetVersion,
            payload: ["notes": .string("## 新しい機能")],
            issuedAt: Timestamp(rawValue: "2026-11-25T02:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsPublishIntent() throws {
        let intent = try PublishGitHubReleaseIntent(envelope: envelope(target: .init(type: "release", id: "1.1.0"), targetVersion: "2"))
        #expect(intent.target.version.rawValue == "1.1.0")
        #expect(intent.target.notesVersion == 2)
        #expect(intent.target.target == .init(type: "release", id: "1.1.0"))
        #expect(intent.target.targetVersion == "2")
        #expect(intent.notes == "## 新しい機能")
    }

    @Test(arguments: [
        (IntentEnvelope.Target?.none, "1"),
        (IntentEnvelope.Target(type: "epic", id: "1.1.0"), "1"),
        (IntentEnvelope.Target(type: "release", epic: ULID(rawValue: "01JCEP1C000000000000000001"), id: "1.1.0"), "1"),
        (IntentEnvelope.Target(type: "release", id: "../1.1.0"), "1"),
        (IntentEnvelope.Target(type: "release", id: nil), "1"),
        (IntentEnvelope.Target(type: "release", id: "1.1.0"), "0"),
        (IntentEnvelope.Target(type: "release", id: "1.1.0"), "01")
    ])
    func rejectsWrongTarget(target: IntentEnvelope.Target?, targetVersion: String) {
        #expect(throws: MalformedIntent.self) {
            try PublishGitHubReleaseIntent(envelope: envelope(target: target, targetVersion: targetVersion))
        }
    }

    @Test func rejectsMissingRepository() {
        #expect(throws: MalformedIntent.self) {
            try PublishGitHubReleaseIntent(envelope: envelope(target: .init(type: "release", id: "1.1.0"), targetVersion: "1", repo: nil))
        }
    }

    @Test(arguments: ["1", "1.0", "1.0.0", "0.9.12", "2026.11.3"])
    func readsMarketingVersion(_ text: String) {
        #expect(MarketingVersion(rawValue: text)?.rawValue == text)
    }

    @Test(arguments: ["", "v1.0.0", "1.0.0.0", "01.0", "1..0", "1.0.", ".1", "1.-1", "1.0 ", "12345.0", "1.0\n", "１.0"])
    func rejectsMalformedMarketingVersion(_ text: String) {
        #expect(MarketingVersion(rawValue: text) == nil)
    }

    @Test(arguments: [("1.0.0", "1.1.0"), ("1.2.9", "1.3.0"), ("2.1", "2.2"), ("3", "3.1"), ("0.9.12", "0.10.0")])
    func nextMinor(from current: String, to next: String) throws {
        #expect(try #require(MarketingVersion(rawValue: current)).nextMinor.rawValue == next)
    }

    @Test func comparesVersionsByNumbers() throws {
        let version = { (text: String) in MarketingVersion(rawValue: text)! }
        // 足りない数は 0 とみなすので、どちらも小さくない
        #expect(!(version("1.2") < version("1.2.0")) && !(version("1.2.0") < version("1.2")))
        #expect(version("1.9.0") < version("1.10.0"))
        #expect(version("1.0.9") < version("1.1"))
        #expect(version("2") > version("1.99.99"))
        #expect(version("1.0.0").tagName == "v1.0.0")
    }

    @Test func pathsUseTheVersion() throws {
        let repo = try #require(RepositoryFullName(rawValue: "shariverse/oshikatsu-countdown-ios"))
        let version = try #require(MarketingVersion(rawValue: "1.1.0"))
        #expect(StatePath.releases(repo) == "repos/shariverse/oshikatsu-countdown-ios/releases")
        #expect(StatePath.release(repo, version) == "repos/shariverse/oshikatsu-countdown-ios/releases/1.1.0.json")
    }

    @Test func tellsWhereTheReleaseStands() throws {
        let vectors = try #require(try JSONSerialization.jsonObject(with: Vectors.data("state/release.json")) as? [String: Any])
        let cases = try #require(vectors["cases"] as? [[String: Any]])
        func file(_ name: String) throws -> ReleaseFile {
            let value = try #require(cases.first { $0["name"] as? String == name }?["value"])
            return try StateFileCoder.decode(ReleaseFile.self, from: JSONSerialization.data(withJSONObject: value))
        }
        // 下書きがあって、まだ公開を押していない版だけが、人の番
        #expect(try file("detected").awaitsNotesReview == false)
        #expect(try file("awaiting-notes").awaitsNotesReview)
        #expect(try file("confirmed").awaitsNotesReview == false)
        #expect(try file("finished-by-hand").awaitsNotesReview == false)
        // タグ・GitHub Release・次の版がそろったら終わり
        #expect(try file("finished-by-hand").isFinished)
        #expect(try file("confirmed").isFinished == false)
        #expect(try file("awaiting-notes").isFinished == false)
    }
}
