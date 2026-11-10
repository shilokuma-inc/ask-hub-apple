@testable import AskHub
import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 状態リポジトリの窓口: ファイルを画面用のモデルに変えること、人の意図を署名して置くこと、処理を待つ意図を先に出すこと
@MainActor
struct StateClientServiceTests {
    static let repo = "example/sample-ios"
    static let epicID = "01JCEP1C000000000000000001"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 窓口と、その窓口が読み書きする状態リポジトリ・署名の鍵
    struct Fixture {
        let service: StateClientService
        let store: InMemoryStateStore
        let key: DeviceSigningKey
    }

    func makeService(files: [String: String] = Self.askingEpic()) throws -> Fixture {
        let store = InMemoryStateStore(files: files.mapValues { Data($0.utf8) })
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let now = now
        return Fixture(service: StateClientService(store: store, key: key) { now }, store: store, key: key)
    }

    /// 質問を待っている epic（Q1 は答えられる、Q2 は Q1 の回答待ちでロック）
    static func askingEpic(stage: String = "asking", extra: [String: String] = [:]) -> [String: String] {
        let base = "repos/\(repo)/epics/\(epicID)"
        return [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":null,
             "protection":{"appliedAt":null},"addedAt":"2026-11-01T00:00:00Z"}
            """,
            "\(base)/epic.json": """
            {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
             "mac":null,"branch":null,"finalPullRequest":null,"goalVersion":null,"origin":null,
             "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T01:00:00Z"}
            """,
            "\(base)/questions.json": """
            {"v":1,"questions":[
              {"id":"q1","version":2,"title":"ランキングの単位","why":"集計と画面に関わる",
               "options":[{"label":"日ごと","effect":"毎日入れ替わる"},{"label":"週ごと","effect":"集計の保存が要る"}],
               "recommended":"日ごと","reason":"今の仕組みのまま作れる","dependsOn":[],"round":1,"state":"open","explanations":[],
               "caution":{"kind":"privacy","reason":"利用者ごとの記録を集める"}},
              {"id":"q2","version":1,"title":"表示する件数","why":"画面の高さが変わる",
               "options":[{"label":"10 件","effect":"1 画面に収まる"},{"label":"50 件","effect":"送って見る"}],
               "recommended":"10 件","reason":"1 画面で見られる","dependsOn":["q1"],"round":1,"state":"locked","explanations":[]}
            ]}
            """,
            "macs/mac-mini.json": """
            {"v":1,"mac":"mac-mini","kind":"alwaysOn","seenAt":"2027-01-15T07:50:00Z","versions":{"worker":"1.0.0","xcode":"27.1"},
             "diskFreeGB":120,"load":3.2,"capacity":{"claude":2,"build":1},
             "selfCheck":{"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok"}}
            """
        ].merging(extra) { _, new in new }
    }

    /// 状態リポジトリのファイルを、画面の epic・質問・リポジトリ・Mac にする
    @Test
    func buildsSnapshotFromStateFiles() async throws {
        let service = try makeService().service
        let snapshot = try await service.fetchSnapshot()

        #expect(snapshot.repositories.map(\.fullName) == [Self.repo])
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.stage == .questions)
        #expect(epic.repositoryID == Self.repo)
        #expect(epic.request.summary == "ランキングの表示を変える")
        #expect(epic.questions.map(\.id) == ["Q1", "Q2"])
        let first = try #require(epic.question("Q1"))
        #expect(first.state == .open)
        // 回答では選択肢を label で送るので、選択肢の id は label にする
        #expect(first.options.map(\.id) == ["日ごと", "週ごと"])
        #expect(first.recommendedOptionID == "日ごと")
        #expect(first.caution == .privacy)
        #expect(epic.question("Q2")?.state == .locked)
        #expect(epic.question("Q2")?.dependsOn == ["Q1"])

        let mac = try #require(snapshot.macs.first)
        #expect(mac.id == "mac-mini")
        #expect(mac.residency == .always)
        #expect(mac.loadAverage == 3.2)
        #expect(mac.freeBytes == 120_000_000_000)
        // ワーカーがビルドとテストに使う Xcode の版は、機種ではなく Xcode の欄に出す（生きている印に機種は無い）
        #expect(mac.xcodeVersion == "27.1")
        #expect(mac.model.isEmpty)
    }

    /// 回答は、読んだときの質問の版を付けて署名し、`intents/<鍵>/` に置く。処理を待つ間は、回答した結果として出す
    @Test
    func answerIsSignedWithQuestionVersionAndShownUntilProcessed() async throws {
        let fixture = try makeService()
        let service = fixture.service, store = fixture.store, key = fixture.key
        _ = try await service.fetchSnapshot()
        try await service.perform(.answer(epicID: Self.epicID, questionID: "Q1", optionID: "週ごと", note: "月曜に入れ替える"))

        let envelope = try await sentEnvelope(in: store, key: key)
        #expect(envelope.kind == AnswerIntent.kind)
        #expect(envelope.repo?.rawValue == Self.repo)
        #expect(envelope.target?.epic?.rawValue == Self.epicID)
        #expect(envelope.target?.id == "q1")
        #expect(envelope.targetVersion == "2")
        #expect(envelope.string("choice") == "週ごと")
        #expect(envelope.string("note") == "月曜に入れ替える")

        let snapshot = try await service.fetchSnapshot()
        let question = try #require(snapshot.epic(Self.epicID)?.question("Q1"))
        guard case .answered(let response) = question.state else {
            Issue.record("処理を待つ回答が、回答として出ていない: \(question.state)")
            return
        }
        #expect(response.optionID == "週ごと")
        #expect(snapshot.sentIntents.first?.state == .waiting)
        // 送った意図の記録は、画面の意図と同じ対象（反映中を出す場所）を持つ
        let intent = HumanIntent.answer(epicID: Self.epicID, questionID: "Q1", optionID: "週ごと", note: "")
        #expect(snapshot.sentIntents.first?.target == intent.targets.first)
        #expect(snapshot.sentIntents.first?.target == .question(epicID: Self.epicID, questionID: "Q1"))
    }

    /// 司令塔が受け付けなかった意図は、先に出すのをやめ、理由を epic の履歴と送った意図の一覧に出す
    @Test
    func rejectedIntentIsShownWithReason() async throws {
        let fixture = try makeService()
        let service = fixture.service, store = fixture.store, key = fixture.key
        _ = try await service.fetchSnapshot()
        try await service.perform(.answer(epicID: Self.epicID, questionID: "Q1", optionID: "日ごと", note: ""))
        let envelope = try await sentEnvelope(in: store, key: key)
        let consumed = #"{"v":1,"kind":"answer","consumedAt":"2027-01-15T08:00:00Z","result":"rejected","reason":"質問の版が古い"}"#
        await store.put(StatePath.consumed(device: key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))

        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.question("Q1")?.state == .open)
        #expect(epic.history.contains { $0.isFailure && $0.text.contains("質問の版が古い") })
        guard case .rejected(_, let reason)? = snapshot.sentIntents.first?.state else {
            Issue.record("受け付けなかった意図が、送った意図の一覧に出ていない")
            return
        }
        #expect(reason == "質問の版が古い")
    }

    /// 依頼は、司令塔が受け取る前から、依頼の意図から決まる id の epic として出す（受け取った後も同じ id）
    @Test
    func requestIsShownAsEpicBeforeCommanderReceivesIt() async throws {
        let fixture = try makeService()
        let service = fixture.service, store = fixture.store, key = fixture.key
        _ = try await service.fetchSnapshot()
        try await service.perform(.request(repositoryID: Self.repo, summary: "週ごとのまとめ", body: "毎朝の通知をやめたい"))

        let envelope = try await sentEnvelope(in: store, key: key)
        #expect(envelope.kind == RequestIntent.kind)
        #expect(envelope.string("title") == "週ごとのまとめ")
        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(StateSnapshotBuilder.epicID(forRequest: envelope).rawValue))
        #expect(epic.stage == .request)
        #expect(epic.title == "週ごとのまとめ")
        #expect(epic.request.body == "毎朝の通知をやめたい")
    }

    /// 依頼の控えは、司令塔が受け取る前から出す epic の id を持つ（送った後は、その epic へ移る）
    @Test
    func requestReceiptPointsToShownEpic() async throws {
        let service = try makeService().service
        _ = try await service.fetchSnapshot()
        let receipt = try await service.perform(.request(repositoryID: Self.repo, summary: "メモ並べ替え", body: "長押しで並べ替える"))
        let epicID = try #require(receipt.requestedEpicID)
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.epic(epicID)?.title == "メモ並べ替え")
        #expect(snapshot.epic(epicID)?.history.last?.text == "依頼を送りました。司令塔が受け取るのを待っています")
        // 依頼でない意図の控えは、移る先を持たない
        #expect(try await service.perform(.discard(epicID: Self.epicID)).requestedEpicID == nil)
    }

    /// 送った意図は、読み直す前も後も、司令塔が受け取るまで受け取り待ちとして覚える。中身か対象の版が違えば別の意図
    @Test
    func remembersSentIntentUntilCommanderReceivesIt() async throws {
        let fixture = try makeService()
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let answer = HumanIntent.answer(epicID: Self.epicID, questionID: "Q1", optionID: "日ごと", note: "")
        #expect(service.lastSend(of: answer) == nil)

        try await service.perform(answer)
        #expect(service.lastSend(of: answer) == SentRecord(sentAt: now, isWaiting: true))
        #expect(service.lastSend(of: .answer(epicID: Self.epicID, questionID: "Q1", optionID: "週ごと", note: "")) == nil)

        // 読み直した後は、状態リポジトリの「送った意図」から決める
        _ = try await service.fetchSnapshot()
        #expect(service.lastSend(of: answer)?.isWaiting == true)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let consumed = #"{"v":1,"kind":"answer","consumedAt":"2027-01-15T08:00:00Z","result":"accepted"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))
        _ = try await service.fetchSnapshot()
        #expect(service.lastSend(of: answer)?.isWaiting == false)
    }

    /// 同じ内容の依頼は、送った時刻を返す（司令塔が受け取った後も。重ねて送るかを確かめるのに使う）
    @Test
    func remembersSentRequestWithItsTime() async throws {
        let service = try makeService().service
        _ = try await service.fetchSnapshot()
        let request = HumanIntent.request(repositoryID: Self.repo, summary: "メモ並べ替え", body: "長押しで並べ替える")
        try await service.perform(request)
        _ = try await service.fetchSnapshot()
        #expect(service.lastSend(of: request)?.sentAt == now)
        #expect(service.lastSend(of: .request(repositoryID: Self.repo, summary: "メモ並べ替え", body: "ドラッグで並べ替える")) == nil)
    }

    /// 大きすぎると分かった epic は、分け方の案を出し、分け方の判断は着手前の確認の結果の版を付けて送る
    @Test
    func splitDecisionUsesReadinessVersion() async throws {
        let readiness = """
        {"v":1,"version":3,"verdict":"tooLarge","reason":"集計と画面が 1 つに収まらない",
         "split":[{"title":"集計","summary":"日ごとの集計を作る"},{"title":"画面","summary":"ランキングの画面を作る"}],
         "round":2,"checkedAt":"2026-11-01T02:00:00Z"}
        """
        let files = Self.askingEpic(stage: "awaitingSplit", extra: ["repos/\(Self.repo)/epics/\(Self.epicID)/readiness.json": readiness])
        let fixture = try makeService(files: files)
        let service = fixture.service, store = fixture.store, key = fixture.key
        let snapshot = try await service.fetchSnapshot()
        let split = try #require(snapshot.epic(Self.epicID)?.split)
        #expect(split.parts.map(\.title) == ["集計", "画面"])
        #expect(split.choice == nil)

        try await service.perform(.decideSplit(epicID: Self.epicID, choice: .split))
        let envelope = try await sentEnvelope(in: store, key: key)
        #expect(envelope.kind == DecideSplitIntent.kind)
        #expect(envelope.targetVersion == "3")
        #expect(envelope.string("choice") == "split")
        let after = try await service.fetchSnapshot()
        // やめた epic は、やめたときの段階（着手前の確認）のまま、やめたことを持つ
        #expect(after.epic(Self.epicID)?.stage == .preflight)
        #expect(after.epic(Self.epicID)?.isAbandoned == true)
        #expect(after.epic(Self.epicID)?.split?.choice == .split)
    }

    /// まだ送れない段階 3 の操作（引き継ぎ・一時停止など）と、最終 PR を出す前の epic へのマージは送れない（ボタンを出さない）。
    /// 人に渡されたジョブへの操作は、そのジョブが無ければ送れない
    @Test
    func stageThreeIntentsAreNotSupported() async throws {
        let service = try makeService().service
        _ = try await service.fetchSnapshot()
        #expect(service.supports(.answer(epicID: Self.epicID, questionID: "Q1", optionID: nil, note: "")))
        #expect(!service.supports(.merge(epicID: Self.epicID, headCommit: "abc")))
        #expect(!service.supports(.handOver(epicID: Self.epicID, macID: "mac-mini")))
        #expect(!service.supports(.resolveBlocker(epicID: Self.epicID, action: .retry, instruction: "")))
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.pause(epicID: Self.epicID))
        }
    }

    /// 開始する前の epic は取り下げられる（版は付けない）。処理を待つ間はやめたと出し、受け付けなかったら理由を出して戻す
    @Test
    func epicBeforeStartIsAbandoned() async throws {
        let fixture = try makeService()
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        #expect(service.supports(.discard(epicID: Self.epicID)))
        try await service.perform(.discard(epicID: Self.epicID))

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == AbandonEpicIntent.kind)
        #expect(envelope.target == IntentEnvelope.Target(type: EpicTarget.targetType, epic: ULID(rawValue: Self.epicID)))
        #expect(envelope.targetVersion == nil)
        let abandoned = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(abandoned.isAbandoned)
        #expect(abandoned.stage == .questions)
        #expect(!service.supports(.discard(epicID: Self.epicID)))
        // やめた epic の質問には答えない
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.answer(epicID: Self.epicID, questionID: "Q1", optionID: "日ごと", note: ""))
        }

        let consumed = #"{"v":1,"kind":"abandonEpic","consumedAt":"2027-01-15T08:00:00Z","result":"rejected","reason":"epic はもう始まっている"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))
        let rejected = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(!rejected.isAbandoned)
        #expect(rejected.history.contains { $0.isFailure && $0.text == "取り下げを受け付けませんでした: epic はもう始まっている" })
    }

    /// 開始した epic の取り下げは段階 3 で送るので、まだ送れない
    @Test
    func startedEpicCannotBeAbandoned() async throws {
        let service = try makeService(files: Self.askingEpic(stage: "running")).service
        _ = try await service.fetchSnapshot()
        #expect(!service.supports(.discard(epicID: Self.epicID)))
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.discard(epicID: Self.epicID))
        }
    }

    /// 公開鍵の記録をつないで、この端末の鍵が登録されたかを確かめる
    @Test
    func keyRegistrationFollowsLedger() async throws {
        let store = InMemoryStateStore()
        let first = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let phone = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let writer = KeyLedgerWriter(store: store, key: first)

        #expect(await KeyRegistration.read(from: store, device: phone.keyID) == .notRegistered(account: nil))
        _ = try await writer.registerFirst(account: "someone", label: "Mac")
        #expect(await KeyRegistration.read(from: store, device: phone.keyID) == .notRegistered(account: "someone"))
        _ = try await writer.add(publicKeyDER: phone.publicKeyDER, account: "someone", label: "iPhone")
        #expect(await KeyRegistration.read(from: store, device: phone.keyID) == .registered(label: "iPhone"))
    }

    func sentEnvelope(in store: InMemoryStateStore, key: DeviceSigningKey) async throws -> IntentEnvelope {
        struct Stored: Decodable {
            var envelope: IntentEnvelope
        }
        let entries = try await store.listAll("\(StatePath.intents)/\(key.keyID.rawValue)") ?? []
        let latest = try #require(entries.max { $0.name < $1.name })
        let data = try #require(await store.data(at: latest.path))
        return try JSONDecoder().decode(Stored.self, from: data).envelope
    }
}
