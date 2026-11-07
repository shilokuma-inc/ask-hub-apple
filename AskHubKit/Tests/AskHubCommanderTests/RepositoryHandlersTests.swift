@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// ビルドの設定を入れる（`configureRepository`）の受け付け
struct RepositoryHandlersTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    static func build(childChecks: [String] = ["build / build"]) throws -> RepositoryFile.Build {
        RepositoryFile.Build(
            xcode: try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS]),
            childChecks: childChecks,
            finalChecks: ["build / build"],
            trustedReviewers: ["coderabbitai[bot]"]
        )
    }

    private func intake(_ store: any StateStore) -> IntentIntake {
        IntentIntake(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now },
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["configureRepository": ConfigureRepositoryHandler()]
        )
    }

    /// 署名したビルドの設定の意図を `intents/` に置く
    private func configure(_ payload: [String: JSONValue], in store: InMemoryStateStore) async throws {
        let nonce = ULID.generate(at: Self.now)
        let envelope = IntentEnvelope(
            kind: ConfigureRepositoryIntent.kind,
            repo: Self.repo,
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
    }

    private func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    private func registered() async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        return store
    }

    @Test func writesBuildAndReplacesItWhenSentAgain() async throws {
        let store = try await registered()
        try await configure(ConfigureRepositoryIntent.payload(for: Self.build()), in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "configureRepository")])
        #expect(try await repository(in: store)?.build == Self.build())

        // 送り直すと、まるごと置き換える（ほかの欄は変えない）
        let changed = try Self.build(childChecks: ["build / build", "lint / lint"])
        try await configure(ConfigureRepositoryIntent.payload(for: changed), in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "configureRepository")])
        let file = try #require(try await repository(in: store))
        #expect(file.build == changed)
        #expect(file.maxConcurrentEpics == 1)
    }

    @Test func refusesUnregisteredRepositoryAndMalformedBuild() async throws {
        let empty = InMemoryStateStore()
        try await configure(ConfigureRepositoryIntent.payload(for: Self.build()), in: empty)
        let reason = "shilokuma-inc/askhub-sandbox は対象のリポジトリに加えていない。先に対象に加える"
        #expect(try await intake(empty).processPending() == [.rejected(kind: "configureRepository", reason: reason)])
        // 対象に加えていなければ repo.json を作らない
        #expect(try await repository(in: empty) == nil)

        let store = try await registered()
        guard case var .object(build)? = ConfigureRepositoryIntent.payload(for: try Self.build())["build"] else {
            Issue.record("build が object でない")
            return
        }
        build["childChecks"] = .array([])
        try await configure(["build": .object(build)], in: store)
        guard case let .rejected(_, reason)? = try await intake(store).processPending().first else {
            Issue.record("受け付けてしまった")
            return
        }
        #expect(reason.hasPrefix("ビルドの設定の形が違う"))
        #expect(try await repository(in: store)?.build == nil)
    }
}
