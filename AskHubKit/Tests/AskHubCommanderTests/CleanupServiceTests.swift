@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// 片付けを探す・消すことを数えるだけの、この Mac の代わり
final class RecordingCleanupMachine: CleanupMachine {
    private let state = OSAllocatedUnfairLock<(scans: Int, removed: [String])>(initialState: (0, []))
    let candidates: [CleanupCandidatesFile.Candidate]
    /// 消すときに断る候補の id と理由
    let refusals: [String: String]

    init(candidates: [CleanupCandidatesFile.Candidate], refusals: [String: String] = [:]) {
        self.candidates = candidates
        self.refusals = refusals
    }

    var scans: Int { state.withLock { $0.scans } }
    var removed: [String] { state.withLock { $0.removed } }

    func scan() async -> CleanupScan {
        state.withLock { $0.scans += 1 }
        return CleanupScan(candidates: candidates, unreadable: ["~/Documents"])
    }

    func remove(_ candidate: CleanupCandidatesFile.Candidate) async -> String? {
        if let reason = refusals[candidate.id] { return reason }
        state.withLock { $0.removed.append(candidate.id) }
        return nil
    }
}

/// 消すときに、その時点の手元の書き置きを写しておく（消している途中で止まったことを再現する）
final class JournalPeekingMachine: CleanupMachine {
    private let state = OSAllocatedUnfairLock<Data?>(initialState: nil)
    let journal: URL
    let candidates: [CleanupCandidatesFile.Candidate]

    init(journal: URL, candidates: [CleanupCandidatesFile.Candidate]) {
        self.journal = journal
        self.candidates = candidates
    }

    var journalWhileRemoving: Data? { state.withLock { $0 } }

    func scan() async -> CleanupScan {
        CleanupScan(candidates: candidates)
    }

    func remove(_ candidate: CleanupCandidatesFile.Candidate) async -> String? {
        let data = try? Data(contentsOf: journal)
        state.withLock { $0 = data }
        return nil
    }
}

/// 片付けの意図を司令塔が頼みに積み、その Mac のワーカーが署名を確かめてから探し・消す
struct CleanupServiceTests {
    static let mac = MacName(rawValue: "macbook-a")!
    static let other = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let clean = candidate(.clone, name: "old", location: "~/old", bytes: 10)
    static let pushed = candidate(.clone, name: "wip", location: "~/wip", bytes: 30, caution: "未 push のコミットがある")
    static let simulator = candidate(.simulator, name: "iPhone（iOS 26.5）", location: "11111111-1111-1111-1111-111111111111", bytes: 20)

    /// 種類と場所から id を求めた候補（ワーカーが探して書くものと同じ）
    static func candidate(
        _ kind: CleanupCandidateKind,
        name: String,
        location: String,
        bytes: Int64,
        caution: String? = nil
    ) -> CleanupCandidatesFile.Candidate {
        let id = CleanupCandidatesFile.Candidate.id(kind: kind, location: location)
        return .init(id: id, kind: kind, name: name, location: location, bytes: bytes, caution: caution)
    }

    let key = P256.Signing.PrivateKey()
    let store = InMemoryStateStore()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var verifier: IntentVerifier { IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]) }
    var context: CommanderContext { CommanderContext(store: store, mac: Self.mac) { Self.now } }

    /// 署名した片付けの意図を置き、その封筒を返す
    func signed(_ kind: String, payload: [String: JSONValue], nonce: Int) async throws -> IntentEnvelope {
        let nonce = try #require(ULID(rawValue: "01JCJ0C00000000000000000\(String(format: "%02d", nonce))"))
        let envelope = IntentEnvelope(
            kind: kind,
            repo: nil,
            target: nil,
            targetVersion: nil,
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return envelope
    }

    /// 司令塔として意図を受け付けて頼みに積む
    @discardableResult
    func accept(_ envelope: IntentEnvelope, mac: MacName = mac) async throws -> IntentDecision {
        let check = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let heartbeat = MacFile(
            mac: mac,
            kind: .resident,
            seenAt: Timestamp(Self.now),
            versions: .init(worker: "1.0.0"),
            diskFreeGB: 100,
            load: 1,
            capacity: .init(claude: 1, build: 1),
            selfCheck: check
        )
        await store.put(StatePath.mac(mac), data: try StateFileCoder.encode(heartbeat))
        let commander = CommanderContext(store: store, mac: Self.other) { Self.now }
        return try await CleanupRequestHandler().handle(envelope, in: commander)
    }

    func candidates() async throws -> CleanupCandidatesFile {
        try StateFileCoder.decode(CleanupCandidatesFile.self, from: #require(await store.data(at: StatePath.cleanupCandidates(Self.mac))))
    }

    func run(_ service: CleanupService) async {
        await service.poll(verifier: verifier)
        await service.waitForRunning()
    }

    @Test func findsThenRemovesOnlyOwnCandidatesWithoutCaution() async throws {
        let machine = RecordingCleanupMachine(
            candidates: [Self.clean, Self.pushed, Self.simulator], refusals: [Self.simulator.id: "起動しているので消さなかった"]
        )
        let service = CleanupService(context: context, machine: machine) { _ in }
        let find = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1)
        #expect(try await accept(find) == .accept)
        await run(service)
        var file = try await candidates()
        #expect(machine.scans == 1)
        #expect(file.scannedAt == Timestamp(Self.now))
        // 大きいものから並べる
        #expect(file.candidates.map(\.id) == [Self.pushed.id, Self.simulator.id, Self.clean.id])
        #expect(file.unreadable == ["~/Documents"])
        #expect(file.handled.map(\.action) == [.find])
        // 済ませた頼みは、もう一度は動かさない
        await run(service)
        #expect(machine.scans == 1)

        let ids: [JSONValue] = [Self.clean.id, Self.pushed.id, Self.simulator.id, "ffffffffffffffff"].map(JSONValue.string)
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue), "scannedAt": .string(Timestamp(Self.now).rawValue), "candidates": .array(ids)
        ]
        let remove = try await signed("removeCleanupCandidates", payload: payload, nonce: 2)
        #expect(try await accept(remove) == .accept)
        await run(service)
        file = try await candidates()
        #expect(machine.removed == [Self.clean.id])
        #expect(file.candidates.map(\.id) == [Self.pushed.id, Self.simulator.id])
        let record = try #require(file.handled.last)
        #expect(record.removed == [Self.clean.id])
        #expect(record.skipped == [
            .init(id: Self.pushed.id, reason: "未 push のコミットがあるので消さなかった"),
            .init(id: Self.simulator.id, reason: "起動しているので消さなかった"),
            .init(id: "ffffffffffffffff", reason: "候補に無い（もう消した・探し直した）")
        ])
    }

    /// 選んだ後に探し直していれば、何も消さない
    @Test func removesNothingWhenScannedAgainAfterChoosing() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(service)
        let old = Timestamp(Self.now.addingTimeInterval(-60)).rawValue
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue), "scannedAt": .string(old), "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        await run(service)
        #expect(machine.removed.isEmpty)
        #expect(try await candidates().handled.last?.problem == "選んだ後に探し直したので、何も消さなかった。もう一度選んでください")
    }

    /// 頼みの元の意図が無い・署名が合わない・ほかの Mac 宛て・中身が違うときは、探しも消しもしない
    @Test func refusesRequestsWhoseOriginCannotBeTrusted() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        let time = Timestamp(Self.now)
        let missing = IntentReference(keyId: keyID, nonce: try #require(ULID(rawValue: "01JCJ0C0000000000000000099")))
        let otherMac = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.other.rawValue)], nonce: 3)
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue), "scannedAt": .string(time.rawValue), "candidates": .array([.string(Self.clean.id)])
        ]
        let forgedRemove = try await signed("removeCleanupCandidates", payload: payload, nonce: 4)
        // 司令塔を通さずに書かれた頼み（中身が元の意図と違う・元の意図が無い・ほかの Mac 宛て）
        let requests = CleanupRequestsFile(requests: [
            .init(intent: missing, action: .find, acceptedAt: time),
            .init(intent: IntentReference(keyId: keyID, nonce: otherMac.nonce), action: .find, acceptedAt: time),
            .init(
                intent: IntentReference(keyId: keyID, nonce: forgedRemove.nonce),
                action: .remove,
                candidates: ["0000000000000009"],
                scannedAt: time,
                acceptedAt: time
            )
        ])
        await store.put(StatePath.cleanupRequests(Self.mac), data: try StateFileCoder.encode(requests))
        for _ in 0..<3 {
            await run(service)
        }
        #expect(machine.scans == 0)
        #expect(machine.removed.isEmpty)
        #expect(try await candidates().handled.map(\.problem) == [
            "元の人の意図が無い・署名を確かめられない", "元の人の意図がこの Mac 宛てでない", "頼みの中身が元の人の意図と違う"
        ])
    }

    /// 司令塔は、登録されていない Mac 宛ての意図を断り、同じ意図は 2 回積まず、頼みは新しい 20 件だけ残す
    @Test func commanderQueuesRequestsPerMac() async throws {
        let unknown = try await signed("findCleanupCandidates", payload: ["mac": .string("imac")], nonce: 1)
        let commander = CommanderContext(store: store, mac: Self.other) { Self.now }
        #expect(try await CleanupRequestHandler().handle(unknown, in: commander) == .reject("Mac imac が登録されていない（ワーカーが一度も動いていない）"))
        let find = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 2)
        try await accept(find)
        try await accept(find)
        let path = StatePath.cleanupRequests(Self.mac)
        var file = try StateFileCoder.decode(CleanupRequestsFile.self, from: #require(await store.data(at: path)))
        #expect(file.requests.map(\.intent.nonce) == [find.nonce])
        for number in 3..<(2 + CleanupRequestsFile.keptRequests) {
            try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: number))
        }
        // 済ませていない頼みだけで上限なら、落とさずに新しい頼みを断る
        let overflow = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 30)
        guard case .reject = try await accept(overflow) else { Issue.record("上限を超えて積んだ"); return }
        file = try StateFileCoder.decode(CleanupRequestsFile.self, from: #require(await store.data(at: path)))
        #expect(file.requests.count == CleanupRequestsFile.keptRequests)
        #expect(file.requests.first?.intent.nonce == find.nonce)
        // ワーカーが済ませた頼みは、古いものから落として積む
        let reference = IntentReference(keyId: keyID, nonce: find.nonce)
        let handled = CleanupCandidatesFile.Handled(intent: reference, action: .find, at: Timestamp(Self.now))
        let done = CleanupCandidatesFile(mac: Self.mac, handled: [handled])
        await store.put(StatePath.cleanupCandidates(Self.mac), data: try StateFileCoder.encode(done))
        let next = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 31)
        #expect(try await accept(next) == .accept)
        file = try StateFileCoder.decode(CleanupRequestsFile.self, from: #require(await store.data(at: path)))
        #expect(file.requests.count == CleanupRequestsFile.keptRequests)
        #expect(!file.requests.contains { $0.intent.nonce == find.nonce })
    }

    /// 候補のファイルの場所だけが書き換えられていれば（id は元の場所から求めたもの）、選んだ id のまま別の場所を消さない
    @Test func refusesCandidateWhoseLocationWasRewritten() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(service)
        var file = try await candidates()
        file.candidates[0].location = "~/Documents"
        await store.put(StatePath.cleanupCandidates(Self.mac), data: try StateFileCoder.encode(file))
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        await run(service)
        #expect(machine.removed.isEmpty)
        #expect(try await candidates().handled.last?.skipped?.first?.reason == "候補の場所が、探したときの id と合わないので消さなかった")
    }

    /// 消した後に結果を書けなければ、次の周で頼みをやり直さずに同じ結果を書き直す（消したものを「消さなかった」と記録しない）
    @Test func republishesResultWithoutRemovingAgain() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(service)
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        await store.failNextWrites(with: [.forbidden(message: nil)])
        await run(service)
        #expect(machine.removed == [Self.clean.id])
        #expect(try await candidates().handled.count == 1)
        await run(service)
        await run(service)
        #expect(machine.removed == [Self.clean.id])
        #expect(try await candidates().handled.last?.removed == [Self.clean.id])
        #expect(try await candidates().candidates.isEmpty)
    }

    /// 結果を書けないまま止まって起動し直しても、手元に残した結果を書き直し、頼みをやり直さない
    @Test func republishesJournaledResultAfterRestart() async throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        let first = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: first, journal: journal) { _ in }
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(service)
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        await store.failNextWrites(with: [.forbidden(message: nil)])
        await run(service)
        #expect(first.removed == [Self.clean.id])
        #expect(FileManager.default.fileExists(atPath: journal.path))

        // 起動し直した（新しい CleanupService）
        let second = RecordingCleanupMachine(candidates: [Self.clean])
        let restarted = CleanupService(context: context, machine: second, journal: journal) { _ in }
        await run(restarted)
        await run(restarted)
        #expect(second.removed.isEmpty)
        #expect(try await candidates().handled.last?.removed == [Self.clean.id])
        #expect(try await candidates().candidates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    /// 消し始める前に書き置きを手元に残し、消している途中で止まって起動し直しても、頼みをやり直さずに「途中で止まった」を書く。
    /// 書き置きを残せなければ、消し始めない
    @Test func recordsInterruptedRemovalInsteadOfRemovingAgain() async throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        let unwritable = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/journal.json")
        let blocked = RecordingCleanupMachine(candidates: [Self.clean])
        let noJournal = CleanupService(context: context, machine: blocked, journal: unwritable) { _ in }
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(noJournal)
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        await run(noJournal)
        #expect(blocked.removed.isEmpty)
        #expect(try await candidates().handled.count == 1)

        let beforeRemoving = try #require(await store.data(at: StatePath.cleanupCandidates(Self.mac)))
        let peeking = JournalPeekingMachine(journal: journal, candidates: [Self.clean])
        await run(CleanupService(context: context, machine: peeking, journal: journal) { _ in })
        let written = try #require(peeking.journalWhileRemoving)
        // 消した直後に止まった（結果を書く前）ことにして、起動し直す
        await store.put(StatePath.cleanupCandidates(Self.mac), data: beforeRemoving)
        try written.write(to: journal)
        let again = RecordingCleanupMachine(candidates: [Self.clean])
        let restarted = CleanupService(context: context, machine: again, journal: journal) { _ in }
        await run(restarted)
        await run(restarted)
        #expect(again.removed.isEmpty)
        #expect(try await candidates().handled.last?.problem == CleanupService.interruptedProblem)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    /// 封筒はあるが署名だけが合わない頼みでは動かない
    @Test func refusesRequestWithTamperedSignature() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        let find = try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1)
        try await accept(find)
        let path = StatePath.intent(device: keyID, nonce: find.nonce)
        let stored = try #require(await store.data(at: path))
        let other = P256.Signing.PrivateKey()
        var object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        object["sig"] = try IntentSignature.sign(envelope: try find.jsonValue(), with: other)
        await store.put(path, data: try JSONSerialization.data(withJSONObject: object))
        await run(service)
        #expect(machine.scans == 0)
        #expect(try await candidates().handled.last?.problem == "元の人の意図が無い・署名を確かめられない")
    }
}
