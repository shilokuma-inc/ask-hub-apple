@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人がする作業: 「終わった」「ファイルを渡す」を、確かめたゴールの版に結びつけて送る。ファイルの中身は意図より先に置く
extension StateClientServiceTests {
    private static let humanTaskBase = "repos/\(repo)/epics/\(epicID)"
    static let plist = Data("<plist><dict><key>PROJECT_ID</key><string>askhub-sandbox</string></dict></plist>".utf8)

    /// h1 は「終わった」、h2 はファイルを渡す、h3 は Secrets に入れる作業。`done` の作業は終えている
    static func humanTaskEpic(stage: String = "running", done: [String] = []) -> [String: String] {
        let tasks = [
            ("h1", "App Group を登録する", #"{"kind":"none"}"#),
            ("h2", "Firebase のプロジェクトを作る", #"{"kind":"file"}"#),
            ("h3", "配信の鍵を入れる", #"{"kind":"secret","name":"ADS_KEY"}"#)
        ]
        let intent = #"{"keyId":"\#(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"}"#
        let human = tasks.map { id, title, handover in
            let state = done.contains(id)
                ? #""state":"done","done":{"intent":\#(intent),"at":"2027-01-15T07:00:00Z","file":null}"#
                : #""state":"pending""#
            return #"{"id":"\#(id)","title":"\#(title)","why":"広告に要る","steps":["手順"],"links":[],"handover":\#(handover),\#(state)}"#
        }
        return askingEpic(extra: [
            "\(humanTaskBase)/epic.json": """
            {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"広告","summary":"広告を出す","discussion":5,"stage":"\(stage)",
             "mac":"mac-mini","branch":null,"finalPullRequest":null,"goalVersion":1,"origin":null,
             "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T06:00:00Z"}
            """,
            "\(humanTaskBase)/goal.json": """
            {"v":1,"version":3,"summary":"広告を出す","decided":[],"outOfScope":[],"doneWhen":["広告が出る"],
             "tasks":[{"id":"t1","title":"広告の SDK を入れる","dependsOn":["h1","h2"],"state":"locked"}],
             "humanTasks":[\(human.joined(separator: ","))]}
            """
        ])
    }

    private func file() throws -> HandoverFile {
        try #require(HandoverFile(name: "GoogleService-Info.plist", data: Self.plist))
    }

    /// 「終わった」は、ゴールの版を付けた humanTaskDone になる。送った後は、司令塔が確かめている間として出し、もう一度は送らせない
    @Test
    func completingHumanTaskSendsDoneWithGoalVersion() async throws {
        let fixture = try makeService(files: Self.humanTaskEpic())
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        #expect(snapshot.epic(Self.epicID)?.humanTask("h3")?.deliverable == .secret(name: "ADS_KEY", repository: Self.repo))
        let intent = HumanIntent.completeHumanTask(epicID: Self.epicID, taskID: "h1")
        #expect(service.supports(intent))
        try await service.perform(intent)

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == HumanTaskDoneIntent.kind)
        #expect(envelope.target == IntentEnvelope.Target(type: "humanTask", epic: ULID(rawValue: Self.epicID), id: "h1"))
        #expect(envelope.targetVersion == "3")
        #expect(envelope.payload?.isEmpty ?? true)
        #expect(try await fixture.store.listAll("attachments")?.isEmpty ?? true)

        let sent = try await service.fetchSnapshot()
        #expect(sent.epic(Self.epicID)?.humanTask("h1")?.state == .verifying)
        #expect(!service.supports(intent))
    }

    /// ファイルを渡す作業は、選んだファイルの大きさとハッシュを封筒に書き、中身を `attachments/<鍵>/<番号>/1` に置く
    @Test
    func handingOverFilePlacesContentWithIntent() async throws {
        let fixture = try makeService(files: Self.humanTaskEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.completeHumanTask(epicID: Self.epicID, taskID: "h2", file: try file()))

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let digest = SHA256.hash(data: Self.plist).map { String(format: "%02x", $0) }.joined()
        let reference = RequestAttachment(number: 1, name: "GoogleService-Info.plist", size: Self.plist.count, sha256: digest)
        #expect(try HumanTaskDoneIntent(envelope: envelope).file == reference)
        let placed = await fixture.store.data(at: StatePath.attachment(device: fixture.key.keyID, nonce: envelope.nonce, number: 1))
        #expect(placed == Self.plist)
    }

    /// 渡すものの種類と合わない操作は送らない。Secrets に入れる作業は、値を受け取らずに「終わった」だけを送る
    @Test
    func handoverMustMatchTask() async throws {
        let fixture = try makeService(files: Self.humanTaskEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        await #expect(throws: ClientServiceError(message: "渡すファイルを選んでください")) {
            try await service.perform(.completeHumanTask(epicID: Self.epicID, taskID: "h2"))
        }
        await #expect(throws: ClientServiceError(message: "この作業では、ファイルを渡しません")) {
            try await service.perform(.completeHumanTask(epicID: Self.epicID, taskID: "h1", file: try file()))
        }
        try await service.perform(.completeHumanTask(epicID: Self.epicID, taskID: "h3"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.target?.id == "h3")
        #expect(envelope.payload?.isEmpty ?? true)
    }

    /// 終えた作業と、司令塔が受け付けない段階の epic の作業は、終えたことを送れない。開始の前（ゴールの確認の待ち）は送れる
    @Test
    func onlyPendingTasksInAcceptedStagesCanBeCompleted() async throws {
        let done = try makeService(files: Self.humanTaskEpic(done: ["h1"])).service
        _ = try await done.fetchSnapshot()
        #expect(!done.supports(.completeHumanTask(epicID: Self.epicID, taskID: "h1")))
        #expect(done.supports(.completeHumanTask(epicID: Self.epicID, taskID: "h2")))

        let checking = try makeService(files: Self.humanTaskEpic(stage: "checking")).service
        _ = try await checking.fetchSnapshot()
        #expect(!checking.supports(.completeHumanTask(epicID: Self.epicID, taskID: "h1")))

        let awaitingStart = try makeService(files: Self.humanTaskEpic(stage: "awaitingStart")).service
        _ = try await awaitingStart.fetchSnapshot()
        #expect(awaitingStart.supports(.completeHumanTask(epicID: Self.epicID, taskID: "h1")))
    }

    /// 司令塔が断ったら、作業に断った理由を出し、もう一度送れるようにする
    @Test
    func rejectedCompletionShowsReason() async throws {
        let fixture = try makeService(files: Self.humanTaskEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let intent = HumanIntent.completeHumanTask(epicID: Self.epicID, taskID: "h1")
        try await service.perform(intent)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let reason = "ゴールが直された（今の版は 4）。新しいゴールを見てから送り直す"
        let consumed = #"{"v":1,"kind":"humanTaskDone","consumedAt":"2027-01-15T08:00:00Z","result":"rejected","reason":"\#(reason)"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))

        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.epic(Self.epicID)?.humanTask("h1")?.state == .verificationFailed(reason: reason))
        #expect(service.supports(intent))
    }
}

/// 渡すファイルの名前・大きさの決まりと、選んだファイルの読み込み
struct HandoverFileTests {
    @Test
    func measuresSizeAndHash() throws {
        let file = try #require(HandoverFile(name: "a.plist", data: Data("abc".utf8)))
        #expect(file.size == 3)
        #expect(file.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(file.attachment == RequestAttachment(number: 1, name: "a.plist", size: 3, sha256: file.sha256))
        // 名前はパスの区切りを含まない。空のファイルは渡さない
        #expect(HandoverFile(name: "../a.plist", data: Data("abc".utf8)) == nil)
        #expect(HandoverFile(name: "a.plist", data: Data()) == nil)
    }

    @Test
    func readsPickedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HandoverFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("GoogleService-Info.plist")
        try Data("plist".utf8).write(to: url)
        #expect(try HandoverFile.read(url).get().name == "GoogleService-Info.plist")
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        #expect(HandoverFile.read(empty) == .failure(HandoverFile.ReadFailure(message: "empty.txt は空なので渡せません")))
        let missing = HandoverFile.read(directory.appendingPathComponent("none.txt"))
        #expect(missing == .failure(HandoverFile.ReadFailure(message: "none.txt を読み込めませんでした")))
    }
}
