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

/// 片付けの意図を司令塔が頼みに積み、その Mac のワーカーが署名を確かめてから探し・消す
struct CleanupServiceTests {
    static let mac = MacName(rawValue: "macbook-a")!
    static let other = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let clean = CleanupCandidatesFile.Candidate(id: "0000000000000001", kind: .clone, name: "old", location: "~/old", bytes: 10)
    static let pushed = CleanupCandidatesFile.Candidate(
        id: "0000000000000002", kind: .clone, name: "wip", location: "~/wip", bytes: 30, caution: "未 push のコミットがある"
    )
    static let simulator = CleanupCandidatesFile.Candidate(
        id: "0000000000000003", kind: .simulator, name: "iPhone（iOS 26.5）", location: "11111111-1111-1111-1111-111111111111", bytes: 20
    )

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
        for number in 3..<(3 + CleanupRequestsFile.keptRequests) {
            try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: number))
        }
        file = try StateFileCoder.decode(CleanupRequestsFile.self, from: #require(await store.data(at: path)))
        #expect(file.requests.count == CleanupRequestsFile.keptRequests)
        #expect(!file.requests.contains { $0.intent.nonce == find.nonce })
    }
}
