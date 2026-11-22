@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 人がする作業の `secret`: 公開鍵を読ませる（`readSecretsKey`）・暗号文を管理用のトークンで GitHub の Secrets に入れてから作業を終える
struct SecretHandoverTests {
    static let repo = HumanTaskFlowTests.repo
    static let now = HumanTaskFlowTests.now
    static let epicID = HumanTaskFlowTests.epicID
    static let keyId = "568250167242549743"
    static let key = Data((0..<32).map(UInt8.init)).base64EncodedString()
    static let encrypted = Data((0..<60).map(UInt8.init)).base64EncodedString()

    let store = InMemoryStateStore()
    var context: CommanderContext { CommanderContext(store: store, mac: EpicHandlersTests.commander) { Self.now } }

    func admin(_ transport: StubTransport, token: String? = ProtectionTests.adminToken) -> AdminGitHub {
        AdminGitHub(tokens: AdminTokens { _ in token }, transport: transport)
    }

    func prepare() async throws {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID,
            repo: Self.repo,
            title: "広告",
            stage: .running,
            mac: HumanTaskFlowTests.laptop,
            goalVersion: 1,
            createdAt: time,
            updatedAt: time
        )
        await store.put(StatePath.epic(Self.repo, Self.epicID), data: try StateFileCoder.encode(epic))
        await store.put(StatePath.goal(Self.repo, Self.epicID), data: try StateFileCoder.encode(HumanTaskFlowTests.goal()))
        let repository = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: time)
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(repository))
    }

    func envelope(_ task: String, secret: EncryptedSecret?) -> IntentEnvelope {
        let target = HumanTaskTarget(repo: Self.repo, epic: Self.epicID, task: task, goalVersion: 1)
        let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
        let nonce = ULID.generate(at: Self.now)
        let done = HumanTaskDoneIntent(target: target, secret: secret, intent: IntentReference(keyId: keyID, nonce: nonce))
        return IntentEnvelope(
            kind: HumanTaskDoneIntent.kind,
            repo: Self.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: done.payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
    }

    func goal() async throws -> GoalFile {
        let data = try await store.data(at: StatePath.goal(Self.repo, Self.epicID))
        return try #require(try data.map { try StateFileCoder.decode(GoalFile.self, from: $0) })
    }

    func repository() async throws -> RepositoryFile {
        let data = try await store.data(at: StatePath.repository(Self.repo))
        return try #require(try data.map { try StateFileCoder.decode(RepositoryFile.self, from: $0) })
    }

    static var publicKeyReply: StubTransport.Reply {
        .json(200, #"{"key_id":"\#(keyId)","key":"\#(key)"}"#)
    }

    /// 公開鍵を読ませると、管理用のトークンで読んで repo.json に書く
    @Test func readsPublicKeyIntoRepositoryFile() async throws {
        try await prepare()
        let transport = StubTransport([Self.publicKeyReply])
        let envelope = IntentEnvelope(
            kind: ReadSecretsKeyIntent.kind,
            repo: Self.repo,
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
        #expect(try await ReadSecretsKeyHandler(admin: admin(transport)).handle(envelope, in: context) == .accept)
        #expect(try await repository().secretsKey == SecretsPublicKey(keyId: Self.keyId, key: Self.key, readAt: Timestamp(Self.now)))
        #expect(transport.requests.map { $0.url?.path } == ["/repos/\(Self.repo)/actions/secrets/public-key"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(ProtectionTests.adminToken)")
        // 管理用のトークンが無ければ読まずに断る
        let none = StubTransport([])
        let refused = try await ReadSecretsKeyHandler(admin: admin(none, token: nil)).handle(envelope, in: context)
        guard case let .reject(reason) = refused else {
            Issue.record("断っていない")
            return
        }
        #expect(reason == AdminTokenProblem.missing(owner: Self.repo.owner).description)
        #expect(none.requests.isEmpty)
    }

    /// 暗号文を、同じ鍵のときだけ Secrets に入れてから作業を終える。司令塔は暗号文をそのまま渡す
    @Test func putsEncryptedValueThenCompletesTask() async throws {
        try await prepare()
        let transport = StubTransport([Self.publicKeyReply, .json(201, "")])
        let secret = EncryptedSecret(keyId: Self.keyId, encryptedValue: Self.encrypted)
        #expect(try await HumanTaskDoneHandler(admin: admin(transport)).handle(envelope("h3", secret: secret), in: context) == .accept)
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /repos/\(Self.repo)/actions/secrets/public-key",
            "PUT /repos/\(Self.repo)/actions/secrets/ADS_KEY"
        ])
        #expect(transport.bodies.last == .object(["encrypted_value": .string(Self.encrypted), "key_id": .string(Self.keyId)]))
        #expect(try await goal().humanTasks[2].state == .done)
    }

    /// 暗号化した鍵が今の公開鍵と違えば、入れずに新しい鍵を書いて断る（作業は終えない）
    @Test func refusesStaleKeyAndRecordsCurrentKey() async throws {
        try await prepare()
        let transport = StubTransport([Self.publicKeyReply])
        let secret = EncryptedSecret(keyId: "111", encryptedValue: Self.encrypted)
        let decision = try await HumanTaskDoneHandler(admin: admin(transport)).handle(envelope("h3", secret: secret), in: context)
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない")
            return
        }
        #expect(reason.contains("公開鍵が変わっていた"))
        #expect(transport.requests.count == 1)
        #expect(try await repository().secretsKey?.keyId == Self.keyId)
        #expect(try await goal().humanTasks[2].state == .pending)
    }

    /// repo.json の鍵が、同じ keyId なのに GitHub の鍵と違う（書き換えられたおそれ）なら、入れずに断り、GitHub の鍵を書き直す
    @Test func refusesWhenRecordedKeyWasReplaced() async throws {
        try await prepare()
        let path = StatePath.repository(Self.repo)
        var file = try await repository()
        let forged = Data(repeating: 7, count: 32).base64EncodedString()
        file.secretsKey = SecretsPublicKey(keyId: Self.keyId, key: forged, readAt: Timestamp(Self.now))
        await store.put(path, data: try StateFileCoder.encode(file))
        let transport = StubTransport([Self.publicKeyReply])
        let secret = EncryptedSecret(keyId: Self.keyId, encryptedValue: Self.encrypted)
        let decision = try await HumanTaskDoneHandler(admin: admin(transport)).handle(envelope("h3", secret: secret), in: context)
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない")
            return
        }
        #expect(reason.contains("書き換えられたおそれ"))
        #expect(transport.requests.count == 1)
        #expect(try await repository().secretsKey?.key == Self.key)
        #expect(try await goal().humanTasks[2].state == .pending)
    }

    /// Secrets に入れる作業でないものに暗号文があれば断る。管理用のトークンを持たない処理は、暗号文を断る
    @Test func refusesSecretForOtherTasksAndWithoutAdmin() async throws {
        try await prepare()
        let secret = EncryptedSecret(keyId: Self.keyId, encryptedValue: Self.encrypted)
        let transport = StubTransport([])
        let other = try await HumanTaskDoneHandler(admin: admin(transport)).handle(envelope("h1", secret: secret), in: context)
        guard case .reject = other else {
            Issue.record("断っていない")
            return
        }
        guard case .reject = try await HumanTaskDoneHandler().handle(envelope("h3", secret: secret), in: context) else {
            Issue.record("断っていない")
            return
        }
        #expect(transport.requests.isEmpty)
        #expect(try await goal().humanTasks.map(\.state) == [.pending, .pending, .pending])
    }
}
