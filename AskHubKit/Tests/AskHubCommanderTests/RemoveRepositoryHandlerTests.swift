@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 対象から外す（`removeRepository`）: 終わっていない epic があれば断り、外したら印を付けてファイルは残す。外したリポジトリには依頼・ビルドの設定を受け付けず、
/// 加え直すと印を外して戻る
struct RemoveRepositoryHandlerTests {
    static let repo = RepositoryHandlersTests.repo
    static let now = RepositoryHandlersTests.now

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    private var intake: IntentIntake {
        IntentIntake(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now },
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: [
                "removeRepository": RemoveRepositoryHandler(),
                "addRepository": AddRepositoryHandler(),
                "request": RequestHandler(),
                "configureRepository": ConfigureRepositoryHandler()
            ]
        )
    }

    /// 署名した意図を置く。`second` で番号の順を決める
    private func send(_ draft: (kind: String, payload: [String: JSONValue]), second: TimeInterval) async throws {
        let nonce = ULID.generate(at: Self.now.addingTimeInterval(second))
        let envelope = IntentEnvelope(
            kind: draft.kind,
            repo: Self.repo,
            payload: draft.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
    }

    private func repository() async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    /// ビルドの設定のあるリポジトリと、`stages` の段階の epic を置く
    private func prepare(epics stages: [EpicStage]) async throws {
        let build = try RepositoryHandlersTests.build()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, build: build, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        for (offset, stage) in stages.enumerated() {
            let id = ULID.generate(at: Self.now.addingTimeInterval(-Double(offset + 1) * 60))
            let time = Timestamp(Self.now)
            let epic = EpicFile(id: id, repo: Self.repo, title: "epic \(offset + 1)", stage: stage, createdAt: time, updatedAt: time)
            await store.put(StatePath.epic(Self.repo, id), data: try StateFileCoder.encode(epic))
        }
    }

    private static let remove = (kind: RemoveRepositoryIntent.kind, payload: [String: JSONValue]())

    @Test func refusesWhileEpicsAreUnfinished() async throws {
        try await prepare(epics: [.merged, .running])
        try await send(Self.remove, second: 0)
        let reason = "終わっていない epic がある: 「epic 2」（running）。取り下げるか、終わってから外す"
        #expect(try await intake.processPending() == [.rejected(kind: "removeRepository", reason: reason)])
        #expect(try await repository()?.isRemoved == false)
    }

    /// 読めない（知らない版の）epic があれば、終わっているかを確かめられないので外さない
    @Test func refusesWhenAnEpicIsUnreadable() async throws {
        try await prepare(epics: [.merged])
        let unknown = ULID.generate(at: Self.now.addingTimeInterval(-3600))
        await store.put(StatePath.epic(Self.repo, unknown), data: Data(#"{"v":99}"#.utf8))
        try await send(Self.remove, second: 0)
        let reason = "読めない epic があり、終わっていない epic が無いかを確かめられない（司令塔を新しくする）"
        #expect(try await intake.processPending() == [.rejected(kind: "removeRepository", reason: reason)])
        #expect(try await repository()?.isRemoved == false)
    }

    @Test func removesKeepingFilesAndRefusesNewWork() async throws {
        try await prepare(epics: [.merged, .abandoned])
        try await send(Self.remove, second: 0)
        try await send((RequestIntent.kind, ["title": .string("色を変えたい")]), second: 1)
        try await send((ConfigureRepositoryIntent.kind, ConfigureRepositoryIntent.payload(for: RepositoryHandlersTests.build())), second: 2)
        // もう一度外しても、何もせずに受け付ける
        try await send(Self.remove, second: 3)
        #expect(try await intake.processPending() == [
            .accepted(kind: "removeRepository"),
            .rejected(kind: "request", reason: "shilokuma-inc/askhub-sandbox は対象から外した。依頼するには加え直す"),
            .rejected(kind: "configureRepository", reason: "shilokuma-inc/askhub-sandbox は対象から外した。設定するには加え直す"),
            .accepted(kind: "removeRepository")
        ])
        let file = try #require(try await repository())
        #expect(file.removedAt == Timestamp(Self.now))
        // ファイルは消さず、ビルドの設定も残す
        #expect(file.build == (try RepositoryHandlersTests.build()))
    }

    @Test func addingAgainClearsTheMark() async throws {
        try await prepare(epics: [])
        try await send(Self.remove, second: 0)
        try await send((AddRepositoryIntent.kind, ["platform": .string("apple")]), second: 1)
        #expect(try await intake.processPending() == [.accepted(kind: "removeRepository"), .accepted(kind: "addRepository")])
        let file = try #require(try await repository())
        #expect(!file.isRemoved)
        #expect(file.build == (try RepositoryHandlersTests.build()))
    }

    @Test func refusesUnregisteredRepository() async throws {
        try await send(Self.remove, second: 0)
        let reason = "shilokuma-inc/askhub-sandbox は対象のリポジトリに加えていない"
        #expect(try await intake.processPending() == [.rejected(kind: "removeRepository", reason: reason)])
        #expect(try await repository() == nil)
    }
}
