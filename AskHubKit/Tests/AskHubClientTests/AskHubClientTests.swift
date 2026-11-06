@testable import AskHubClient
import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// クライアントと非常口が、人の意図を署名して置くことと、公開鍵の記録を足すこと
struct AskHubClientTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)

    func key() throws -> DeviceSigningKey {
        try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
    }

    @Test func registersFirstKeyAndAddsAnother() async throws {
        let store = InMemoryStateStore()
        let first = try key()
        let writer = KeyLedgerWriter(store: store, key: first) { Self.now }
        #expect(try await writer.registerFirst(account: "mrs1669", label: "Mac mini") == 1)
        // 最初の鍵は 1 つだけ
        await #expect(throws: ClientError.self) { try await writer.registerFirst(account: "mrs1669", label: "Mac mini") }
        let second = try key()
        #expect(try await writer.add(publicKeyDER: second.publicKeyDER, account: "mrs1669", label: "iPhone") == 2)

        var records: [JSONValue] = []
        for seq in 1...2 {
            records.append(try JSONValue(parsing: #require(await store.data(at: StatePath.key(seq: seq)))))
        }
        let result = KeyLedger.verify(records, firstKey: first.keyID, accounts: ["mrs1669"])
        #expect(result.problem == nil)
        #expect(Set(result.keys.keys) == [first.keyID, second.keyID])

        #expect(try await writer.revoke(second.keyID) == 3)
        records.append(try JSONValue(parsing: #require(await store.data(at: StatePath.key(seq: 3)))))
        #expect(Set(KeyLedger.verify(records, firstKey: first.keyID, accounts: ["mrs1669"]).keys.keys) == [first.keyID])
    }

    @Test func commanderAcceptsIntentsSentByClient() async throws {
        let store = InMemoryStateStore()
        let key = try key()
        let sender = IntentSender(store: store, key: key) { Self.now }
        let intake = IntentIntake(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now },
            verifier: IntentVerifier(publicKeys: [key.keyID: key.publicKeyDER]),
            handlers: ["addRepository": AddRepositoryHandler(), "request": RequestHandler()]
        )
        // 同じ時刻に送ると番号の順が決まらないので、対象に加えるのを処理してから依頼を送る
        try await sender.send(.addRepository(Self.repo))
        #expect(try await intake.processPending() == [.accepted(kind: "addRepository")])
        let request = try await sender.send(.request(repo: Self.repo, title: "メモに色を付けたい", body: "メモごとに色を選べるようにする"))
        #expect(try await intake.processPending() == [.accepted(kind: "request")])
        let data = try #require(await store.data(at: StatePath.repository(Self.repo)))
        let repository = try StateFileCoder.decode(RepositoryFile.self, from: data)
        #expect(repository.maxConcurrentEpics == 1)
        let epic = RequestHandler.epicID(for: request)
        #expect(await store.data(at: StatePath.epic(Self.repo, epic)) != nil)
    }

    @Test func draftsAreReadAsTheirKinds() throws {
        let key = try key()
        func envelope(_ draft: IntentDraft) -> IntentEnvelope {
            IntentEnvelope(
                kind: draft.kind,
                repo: draft.repo,
                target: draft.target,
                targetVersion: draft.targetVersion,
                payload: draft.payload,
                issuedAt: Timestamp(Self.now),
                nonce: ULID.generate(at: Self.now),
                keyId: key.keyID
            )
        }
        let epic = ULID.generate(at: Self.now)
        let question = QuestionTarget(repo: Self.repo, epic: epic, question: "q1", version: 2)
        let answer = try AnswerIntent(envelope: envelope(.answer(question, choice: "日ごと", note: "")))
        #expect(answer.choice == "日ごと")
        #expect(answer.questionVersion == 2)
        let clarify = try AnswerIntent(envelope: envelope(.clarify(question, note: "保存とは？")))
        #expect(clarify.mode == .clarify)
        let target = EpicTarget(repo: Self.repo, epic: epic, version: 3)
        #expect(try StartEpicIntent(envelope: envelope(.startEpic(target, mac: MacName(rawValue: "mac-mini")!))).mac.rawValue == "mac-mini")
        #expect(try ReviseGoalIntent(envelope: envelope(.reviseGoal(target, instruction: "完了の条件を足して"))).instruction == "完了の条件を足して")
        #expect(try DecideSplitIntent(envelope: envelope(.decideSplit(target, choice: .proceed))).choice == .proceed)
        #expect(try AddRepositoryIntent(envelope: envelope(.addRepository(Self.repo))).platform == .apple)
    }
}

/// 非常口のコマンドの引数
struct CommandArgumentsTests {
    @Test func readsNamedAndPositionalArguments() throws {
        let arguments = try CommandArguments(["revoke-me", "--repo", "shilokuma-inc/askhub-sandbox", "--version", "3"])
        #expect(arguments.positional == ["revoke-me"])
        #expect(try arguments.repository().rawValue == "shilokuma-inc/askhub-sandbox")
        #expect(try arguments.integer("version") == 3)
        #expect(throws: CommandArguments.Failure(message: "--epic が要る")) { try arguments.epic() }
        #expect(throws: CommandArguments.Failure(message: "知らない引数 --version")) { try arguments.only(["repo"]) }
        #expect(throws: CommandArguments.Failure(message: "--repo の値が無い")) { try CommandArguments(["--repo"]) }
        #expect(throws: CommandArguments.Failure(message: "--version は 1 以上の数")) {
            try CommandArguments(["--version", "0"]).integer("version")
        }
    }
}
