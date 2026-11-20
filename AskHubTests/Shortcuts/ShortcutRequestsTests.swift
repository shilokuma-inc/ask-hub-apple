@testable import AskHub
import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// Siri・ショートカットからの依頼: 依頼先の候補を出すこと、確かめてから署名して送ること、送れないときの文言
@MainActor
struct ShortcutRequestsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    struct Fixture {
        let requests: ShortcutRequests
        let store: InMemoryStateStore
        let key: DeviceSigningKey
    }

    static func repoJSON(_ repo: String, removed: Bool = false) -> String {
        let removedAt = removed ? #","removedAt":"2026-11-10T00:00:00Z""# : ""
        return """
        {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":null,
         "protection":{"appliedAt":null},"addedAt":"2026-11-01T00:00:00Z"\(removedAt)}
        """
    }

    static let files = [
        "repos/shilokuma-inc/askhub-sandbox/repo.json": repoJSON("shilokuma-inc/askhub-sandbox"),
        "repos/shilokuma-inc/Removed-App/repo.json": repoJSON("shilokuma-inc/Removed-App", removed: true),
        "repos/another/alpha-ios/repo.json": repoJSON("another/alpha-ios"),
        // 知らない版の repo.json は飛ばす
        "repos/another/future-ios/repo.json": #"{"v":99,"repo":"another/future-ios"}"#
    ]

    /// 公開鍵の記録に最初の鍵を置き、`registered` ならこの端末の鍵も登録する
    func makeFixture(registered: Bool = true, key keyFailure: DeviceSigningKey.Failure? = nil) async throws -> Fixture {
        let store = InMemoryStateStore(files: Self.files.mapValues { Data($0.utf8) })
        let first = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let writer = KeyLedgerWriter(store: store, key: first)
        _ = try await writer.registerFirst(account: "someone", label: "Mac")
        if registered {
            _ = try await writer.add(publicKeyDER: key.publicKeyDER, account: "someone", label: "iPhone")
        }
        let now = now
        let requests = ShortcutRequests(
            dataSource: { .stateRepository },
            connect: {
                ShortcutRequests.Connection(store: store) { () throws(DeviceSigningKey.Failure) in
                    if let keyFailure { throw keyFailure }
                    return key
                }
            },
            now: { now }
        )
        return Fixture(requests: requests, store: store, key: key)
    }

    static let request = ShortcutRequestText("週ごとのまとめ通知\n日曜の夜に 1 回だけ届けたい")!

    /// 依頼先は対象のリポジトリだけ（外したもの・読めないものは出さない）。アプリの依頼先と同じく、持ち主ごとの名前順
    @Test
    func listsTargetRepositoriesWithoutRemovedOnes() async throws {
        let fixture = try await makeFixture()

        let repositories = try await fixture.requests.repositories()

        #expect(repositories.map(\.rawValue) == ["another/alpha-ios", "shilokuma-inc/askhub-sandbox"])
    }

    /// アプリの「新しい依頼」と同じ依頼の意図を、この端末の鍵で署名して置く
    @Test
    func sendsSignedRequestIntent() async throws {
        let fixture = try await makeFixture()

        let sent = try await fixture.requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")

        let stored = try await storedIntents(in: fixture)
        #expect(stored.count == 1)
        // 司令塔と同じ確かめ方（登録した公開鍵での署名・時刻）で読める
        let verifier = IntentVerifier(publicKeys: [fixture.key.keyID: fixture.key.publicKeyDER])
        let envelope = try verifier.verify(stored: try #require(stored.first), now: now)
        #expect(envelope.kind == RequestIntent.kind)
        #expect(envelope.issuedAt == Timestamp(now))
        let request = try RequestIntent(envelope: envelope)
        #expect(request.repo.rawValue == "shilokuma-inc/askhub-sandbox")
        #expect(request.title == "週ごとのまとめ通知")
        #expect(request.body == "日曜の夜に 1 回だけ届けたい")
        // 司令塔が受け取る前から出る epic の id は、意図から決まる
        #expect(sent.epicID == RequestIntent.epicID(for: request.intent))
        #expect(sent.message == "askhub-sandbox に「週ごとのまとめ通知」を依頼しました")
    }

    /// 依頼先の id は大文字小文字を区別せず、状態リポジトリの書き方で送る（状態リポジトリのパスは大文字小文字を区別する）
    @Test
    func sendsWithRepositoryNameFromState() async throws {
        let fixture = try await makeFixture()

        let sent = try await fixture.requests.send(Self.request, to: "Another/Alpha-iOS")

        #expect(sent.repository.rawValue == "another/alpha-ios")
        #expect(try await storedIntents(in: fixture).first?["envelope"]?["repo"]?.stringValue == "another/alpha-ios")
    }

    @Test(arguments: ["shilokuma-inc/Removed-App", "shilokuma-inc/unknown-ios"])
    func refusesRepositoryThatIsNotTarget(repository: String) async throws {
        let fixture = try await makeFixture()

        let error = await #expect(throws: ShortcutRequestError.self) {
            try await fixture.requests.send(Self.request, to: repository)
        }

        #expect(error?.message == "\(repository) は AskHub の対象のリポジトリではありません（外したか、まだ加えていません）")
        #expect(try await storedIntents(in: fixture).isEmpty)
    }

    /// 登録されていない鍵の意図は司令塔に断られ、画面の外からでは気づけないので、送らずに知らせる
    @Test
    func refusesUnregisteredKey() async throws {
        let fixture = try await makeFixture(registered: false)

        let error = await #expect(throws: ShortcutRequestError.self) {
            try await fixture.requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")
        }

        #expect(error?.message == "この端末の鍵がまだ登録されていません。AskHub の設定で登録してから、もう一度依頼してください")
        #expect(try await storedIntents(in: fixture).isEmpty)
    }

    /// ロック中は Keychain の鍵を読めない。解除してからやり直すよう知らせる
    @Test
    func refusesWhenKeyIsUnavailable() async throws {
        let fixture = try await makeFixture(key: .store(.keychain(status: errSecInteractionNotAllowed)))

        let error = await #expect(throws: ShortcutRequestError.self) {
            try await fixture.requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")
        }

        #expect(error == .locked)
        #expect(try await storedIntents(in: fixture).isEmpty)
    }

    /// デモのデータでは、状態リポジトリにつながずに断る（候補も出さない）
    @Test
    func refusesInDemo() async throws {
        let requests = ShortcutRequests(
            dataSource: { .demo },
            connect: { () throws(ShortcutRequestError) in
                Issue.record("デモのデータでは状態リポジトリにつながない")
                throw ShortcutRequestError(message: "")
            }
        )

        await #expect(throws: ShortcutRequestError.demo) {
            try await requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")
        }
        await #expect(throws: ShortcutRequestError.demo) {
            try await requests.repositories()
        }
    }

    @Test
    func refusesTooLongBody() async throws {
        let fixture = try await makeFixture()
        let request = try #require(ShortcutRequestText("要約\n" + String(repeating: "あ", count: RequestIntent.maximumBodyLength + 1)))

        let error = await #expect(throws: ShortcutRequestError.self) {
            try await fixture.requests.send(request, to: "shilokuma-inc/askhub-sandbox")
        }

        #expect(error?.message == "依頼の文は \(RequestIntent.maximumBodyLength) 文字までです")
        #expect(try await storedIntents(in: fixture).isEmpty)
    }

    /// 状態リポジトリを読めないときは、アプリと同じ文言で返す（トークンの値は含めない）
    @Test(arguments: [
        (StateStoreError.tokenUnavailable, "GitHub のトークンがありません。設定で入れてください"),
        (StateStoreError.unauthorized, "GitHub のトークンが無効か、期限が切れています。設定で入れ直してください")
    ])
    func explainsStateFailureWithAppMessage(failure: StateStoreError, message: String) async throws {
        let requests = ShortcutRequests(
            dataSource: { .stateRepository },
            connect: {
                ShortcutRequests.Connection(store: FailingStore(failure: failure)) { () throws(DeviceSigningKey.Failure) in
                    try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
                }
            }
        )

        await #expect(throws: ShortcutRequestError(message: message)) {
            try await requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")
        }
        await #expect(throws: ShortcutRequestError(message: message)) {
            try await requests.repositories()
        }
    }

    /// Siri を閉じたなどの取り消しは、失敗の文言にしない
    @Test
    func passesCancellationThrough() async throws {
        let requests = ShortcutRequests(
            dataSource: { .stateRepository },
            connect: {
                ShortcutRequests.Connection(store: FailingStore(failure: .cancelled)) { () throws(DeviceSigningKey.Failure) in
                    try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
                }
            }
        )

        await #expect(throws: CancellationError.self) {
            try await requests.send(Self.request, to: "shilokuma-inc/askhub-sandbox")
        }
    }

    /// この端末の鍵で置いた意図（`{"envelope": …, "sig": "…"}`）
    private func storedIntents(in fixture: Fixture) async throws -> [JSONValue] {
        let entries = try await fixture.store.listAll("\(StatePath.intents)/\(fixture.key.keyID.rawValue)") ?? []
        var intents: [JSONValue] = []
        for entry in entries {
            intents.append(try JSONValue(parsing: try #require(await fixture.store.data(at: entry.path))))
        }
        return intents
    }
}

/// 読み書きのたびに同じ失敗を返す状態リポジトリ
private struct FailingStore: StateStore {
    let failure: StateStoreError

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        throw failure
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        throw failure
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        throw failure
    }

    func snapshot() async throws(StateStoreError) -> any StateStore {
        throw failure
    }
}
