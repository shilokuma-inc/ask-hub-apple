@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人がする作業の Secrets: 公開鍵を司令塔に読ませ、値はこの端末で暗号化して暗号文だけを送る
extension StateClientServiceTests {
    private static let secretsKeyId = "568250167242549743"

    /// 司令塔が読んだ公開鍵（`repo.json` の `secretsKey`）を足した対象のリポジトリ
    private static func secretsRepository(key: Data) -> [String: String] {
        [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"protection":{},
             "secretsKey":{"keyId":"\(secretsKeyId)","key":"\(key.base64EncodedString())","readAt":"2026-11-22T13:00:00Z"},
             "addedAt":"2026-10-01T00:00:00Z"}
            """
        ]
    }

    @Test
    func readSecretsKeyAsksCommanderForRepository() async throws {
        let fixture = try makeService(files: Self.humanTaskEpic())
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.repository(Self.repo)?.secretsKey == nil)
        let intent = HumanIntent.readSecretsKey(repositoryID: Self.repo)
        #expect(service.supports(intent))
        try await service.perform(intent)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(try ReadSecretsKeyIntent(envelope: envelope).repo.rawValue == Self.repo)
    }

    /// 暗号化した値だけを送る。送った意図には平文が入らない（暗号文が正しく開けることは AskHubKit の SealedBoxTests で確かめる）
    @Test
    func handOverSecretSendsOnlyCiphertext() async throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        var files = Self.humanTaskEpic()
        files.merge(Self.secretsRepository(key: recipient.publicKey.rawRepresentation)) { $1 }
        let fixture = try makeService(files: files)
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        let key = try #require(snapshot.repository(Self.repo)?.secretsKey)
        let value = "ads-secret-値-12345"
        let secret = try #require(HumanTaskView.encrypt(value, with: key))
        #expect(secret.keyId == Self.secretsKeyId)
        #expect(secret.problem == nil)
        try await service.perform(.handOverSecret(epicID: Self.epicID, taskID: "h3", secret: secret))

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let done = try HumanTaskDoneIntent(envelope: envelope)
        #expect(done.secret == secret)
        #expect(done.file == nil)
        // 送った意図に平文は入らない。暗号文は値より 48 バイト（使い捨ての公開鍵とタグ）長い
        let sent = try #require(String(bytes: CanonicalJSON.data(for: try envelope.jsonValue()), encoding: .utf8))
        #expect(!sent.contains(value))
        #expect(Data(base64Encoded: secret.encryptedValue)?.count == Data(value.utf8).count + SealedBox.overhead)
        // 同じ値でも、送るたびに違う暗号文になる
        #expect(HumanTaskView.encrypt(value, with: key) != secret)
    }

    /// Secrets に入れる作業でないものには、暗号文を送らない
    @Test
    func handOverSecretOnlyForSecretTasks() async throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        var files = Self.humanTaskEpic()
        files.merge(Self.secretsRepository(key: recipient.publicKey.rawRepresentation)) { $1 }
        let fixture = try makeService(files: files)
        let snapshot = try await fixture.service.fetchSnapshot()
        let key = try #require(snapshot.repository(Self.repo)?.secretsKey)
        let secret = try #require(HumanTaskView.encrypt("value", with: key))
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.handOverSecret(epicID: Self.epicID, taskID: "h1", secret: secret))
        }
        // 公開鍵の形が違えば暗号化しない
        #expect(HumanTaskView.encrypt("value", with: SecretsPublicKey(keyId: "1", key: "AAAA", readAt: key.readAt)) == nil)
        #expect(HumanTaskView.encrypt("", with: key) == nil)
    }
}
