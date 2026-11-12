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

        // 登録済みの鍵を重ねて登録する記録は書かない
        await #expect(throws: ClientError.self) {
            try await writer.add(publicKeyDER: second.publicKeyDER, account: "mrs1669", label: "iPhone")
        }
        #expect(try await writer.revoke(second.keyID) == 3)
        records.append(try JSONValue(parsing: #require(await store.data(at: StatePath.key(seq: 3)))))
        #expect(Set(KeyLedger.verify(records, firstKey: first.keyID, accounts: ["mrs1669"]).keys.keys) == [first.keyID])
        // 最後の鍵は取り消さない
        await #expect(throws: ClientError.self) { try await writer.revoke(first.keyID) }
        #expect(await store.data(at: StatePath.key(seq: 4)) == nil)
    }

    @Test func noncesIncreaseWithinSameMillisecond() async {
        let sequence = NonceSequence()
        var previous: ULID?
        for _ in 0..<50 {
            let nonce = await sequence.next(at: Self.now)
            if let previous { #expect(nonce > previous) }
            previous = nonce
        }
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

    @Test func commanderAcceptsRequestWithAttachments() async throws {
        let store = InMemoryStateStore()
        let key = try key()
        let sender = IntentSender(store: store, key: key) { Self.now }
        let intake = IntentIntake(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now },
            verifier: IntentVerifier(publicKeys: [key.keyID: key.publicKeyDER]),
            handlers: ["addRepository": AddRepositoryHandler(), "request": RequestHandler()]
        )
        try await sender.send(.addRepository(Self.repo))
        #expect(try await intake.processPending() == [.accepted(kind: "addRepository")])
        let contents = [Data("# 画面の案".utf8), Data("width,height\n1,2".utf8)]
        let files = try [
            #require(RequestAttachment(number: 1, name: "案.md", contents: contents[0])),
            #require(RequestAttachment(number: 2, name: "size.csv", contents: contents[1]))
        ]
        let draft = IntentDraft.request(repo: Self.repo, title: "画面を直したい", body: "添付の案のとおりに", attachments: files)
        let sent = try await sender.send(draft, attachments: contents)
        // 司令塔は、置いた中身の大きさとハッシュが封筒と合うかを確かめてから受け付ける
        #expect(try await intake.processPending() == [.accepted(kind: "request")])
        #expect(await store.data(at: StatePath.attachment(device: sent.keyId, nonce: sent.nonce, number: 2)) == contents[1])
        let epic = RequestHandler.epicID(for: sent)
        #expect(await store.data(at: StatePath.epic(Self.repo, epic)) != nil)
    }

    @Test func verifyDraftIsReadAsVerifyIntent() throws {
        let key = try key()
        let verification = VerificationTarget(repo: Self.repo, epic: ULID.generate(at: Self.now), item: "v2", goalVersion: 3)
        func read(_ draft: IntentDraft) throws -> VerifyIntent {
            try VerifyIntent(envelope: IntentEnvelope(
                kind: draft.kind,
                repo: draft.repo,
                target: draft.target,
                targetVersion: draft.targetVersion,
                payload: draft.payload,
                issuedAt: Timestamp(Self.now),
                nonce: ULID.generate(at: Self.now),
                keyId: key.keyID
            ))
        }
        let problem = try read(.verify(verification, result: .problem, note: "線が見えない"))
        #expect(problem.target == verification)
        #expect(problem.note == "線が見えない")
        #expect(try read(.verify(verification, result: .confirmed)).result == .confirmed)
    }

    @Test func sendsAttachmentsBeforeIntent() async throws {
        let store = InMemoryStateStore()
        let key = try key()
        let sender = IntentSender(store: store, key: key) { Self.now }
        let file = RequestAttachment(number: 1, name: "GoogleService-Info.plist", size: 5, sha256: String(repeating: "a", count: 64))
        let target = HumanTaskTarget(repo: Self.repo, epic: ULID.generate(at: Self.now), task: "h1", goalVersion: 3)
        let sent = try await sender.send(.humanTaskDone(target, file: file), attachments: [Data("plist".utf8)])
        let blob = await store.data(at: StatePath.attachment(device: sent.keyId, nonce: sent.nonce, number: 1))
        #expect(blob == Data("plist".utf8))
        #expect(await store.data(at: StatePath.intent(device: sent.keyId, nonce: sent.nonce)) != nil)
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
        let build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"]
        )
        #expect(try ConfigureRepositoryIntent(envelope: envelope(.configureRepository(Self.repo, build: build))).build == build)
        let job = JobTarget(repo: Self.repo, epic: epic, job: ULID.generate(at: Self.now), attempt: 2)
        #expect(try RetryJobIntent(envelope: envelope(.retry(job))).target == job)
        #expect(try GiveUpJobIntent(envelope: envelope(.giveUp(job))).target == job)
        #expect(try AbandonEpicIntent(envelope: envelope(.abandonEpic(repo: Self.repo, epic: epic))).epic == epic)
        let head = String(repeating: "b", count: 40)
        let final = FinalPullRequestTarget(repo: Self.repo, epic: epic, head: head)
        #expect(try ApproveMergeIntent(envelope: envelope(.approveMerge(final))).target == final)
        #expect(try InstructFinalIntent(envelope: envelope(.instructFinal(final, instruction: "余白を広げて"))).instruction == "余白を広げて")
        let card = DecisionTarget(repo: Self.repo, epic: epic, decision: "d1", head: head)
        let answered = try DecisionIntent(envelope: envelope(.decision(card, answer: .alternative, note: "2 行にする")))
        #expect(answered.answer == .alternative)
        #expect(answered.note == "2 行にする")
        #expect(try DecisionIntent(envelope: envelope(.decision(card, answer: .ok))).note.isEmpty)
        let humanTask = HumanTaskTarget(repo: Self.repo, epic: epic, task: "h1", goalVersion: 3)
        let done = try HumanTaskDoneIntent(envelope: envelope(.humanTaskDone(humanTask)))
        #expect(done.target == humanTask)
        #expect(done.file == nil)
        let file = RequestAttachment(number: 1, name: "key.p8", size: 10, sha256: String(repeating: "b", count: 64))
        #expect(try HumanTaskDoneIntent(envelope: envelope(.humanTaskDone(humanTask, file: file))).file == file)
    }

    /// 試行の前に人に渡したジョブ（直しの上限を超えた直し）には、試行の番号 0 を付けて送り、司令塔がそのまま読める
    @Test func jobDraftsForUntriedJobAreRead() throws {
        let key = try key()
        func envelope(_ draft: IntentDraft) -> IntentEnvelope {
            #expect(draft.targetVersion == "0")
            return IntentEnvelope(
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
        let job = JobTarget(repo: Self.repo, epic: ULID.generate(at: Self.now), job: ULID.generate(at: Self.now), attempt: 0)
        #expect(try RetryJobIntent(envelope: envelope(.retry(job))).target == job)
        #expect(try GiveUpJobIntent(envelope: envelope(.giveUp(job))).target == job)
    }

    /// 一時停止・再開・引き継ぎは、版を付けずに epic を対象にする
    @Test func pauseDraftsAreReadAsTheirKinds() throws {
        let key = try key()
        func envelope(_ draft: IntentDraft) -> IntentEnvelope {
            #expect(draft.targetVersion == nil)
            return IntentEnvelope(
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
        #expect(try PauseEpicIntent(envelope: envelope(.pauseEpic(repo: Self.repo, epic: epic))).epic == epic)
        #expect(try ResumeEpicIntent(envelope: envelope(.resumeEpic(repo: Self.repo, epic: epic))).epic == epic)
        let handover = try HandoverIntent(envelope: envelope(.handover(repo: Self.repo, epic: epic, to: MacName(rawValue: "macbook-a")!)))
        #expect(handover.mac.rawValue == "macbook-a")
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
        // 名前の無い引数（引用符で囲み忘れた本文の続きなど）は、許したときだけ受け付ける
        #expect(throws: CommandArguments.Failure.self) { try arguments.only(["repo", "version"]) }
        try arguments.only(["repo", "version"], positional: true)
        #expect(throws: CommandArguments.Failure(message: "--repo の値が無い")) { try CommandArguments(["--repo"]) }
        #expect(throws: CommandArguments.Failure(message: "--version は 1 以上の数")) {
            try CommandArguments(["--version", "0"]).integer("version")
        }
        // 試行の番号は、試行の前に人に渡したジョブのために 0 から受け付ける
        #expect(try CommandArguments(["--attempt", "0"]).integer("attempt", minimum: 0) == 0)
        #expect(throws: CommandArguments.Failure(message: "--attempt は 0 以上の数")) {
            try CommandArguments(["--attempt", "-1"]).integer("attempt", minimum: 0)
        }
    }
}
