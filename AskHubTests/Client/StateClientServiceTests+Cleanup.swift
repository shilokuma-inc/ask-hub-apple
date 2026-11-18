@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 片付けの候補: ワーカーが書いた候補と、司令塔が積んだまだ済ませていない頼みを Mac に出し、「探す」「消す」を意図にして送る
extension StateClientServiceTests {
    private static let cleanupKey = String(repeating: "k", count: 43)

    private static func cleanupFiles(scanned: Bool, pending: String? = nil) -> [String: String] {
        let reference = { (nonce: Int) in #"{"keyId":"\#(cleanupKey)","nonce":"01JCN0NCE0000000000000000\#(nonce)"}"# }
        var files: [String: String] = [:]
        if scanned {
            files["cleanup/mac-mini/candidates.json"] = """
            {"v":1,"mac":"mac-mini","scannedAt":"2027-01-15T07:30:00Z","candidates":[
              {"id":"0123456789abcdef","kind":"clone","name":"old-habit-ios","location":"~/Desktop/ios/old-habit-ios","bytes":2100000000,
               "lastUsedAt":"2026-09-01T00:00:00Z"},
              {"id":"1123456789abcdef","kind":"clone","name":"wip-ios","location":"~/Desktop/ios/wip-ios","bytes":800000000,
               "caution":"未 push のコミットがある"},
              {"id":"2123456789abcdef","kind":"simulator","name":"iPhone 16 Pro（iOS 26.5）",
               "location":"11111111-1111-1111-1111-111111111111","bytes":6400000000}],
             "unreadable":["~/Documents"],
             "handled":[{"intent":\(reference(1)),"action":"find","at":"2027-01-15T07:30:00Z"},
               {"intent":\(reference(2)),"action":"remove","at":"2027-01-15T07:40:00Z","removed":["3123456789abcdef"],
                "skipped":[{"id":"1123456789abcdef","reason":"未 push のコミットがあるので消さなかった"}]}]}
            """
        }
        if let pending {
            files["cleanup/mac-mini/requests.json"] = """
            {"v":1,"requests":[{"intent":\(reference(1)),"action":"find","acceptedAt":"2027-01-15T07:20:00Z"},
              {"intent":\(reference(3)),"action":"\(pending)","acceptedAt":"2027-01-15T07:50:00Z"\(pending == "remove"
                ? #","candidates":["0123456789abcdef"],"scannedAt":"2027-01-15T07:30:00Z""# : "")}]}
            """
        }
        return files
    }

    @Test
    func buildsCleanupCandidatesAndPendingWorkFromStateFiles() async throws {
        let service = try makeService(files: Self.askingEpic(extra: Self.cleanupFiles(scanned: true, pending: "find"))).service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let mac = try #require(snapshot.mac("mac-mini"))
        try #require(mac.cleanupCandidates.count == 3)
        #expect(mac.cleanupCandidates.map(\.id) == ["0123456789abcdef", "1123456789abcdef", "2123456789abcdef"])
        // clone はホームからのパスで出す
        #expect(mac.cleanupCandidates.first?.name == "~/Desktop/ios/old-habit-ios")
        #expect(mac.cleanupCandidates.first?.kind == .clone)
        #expect(mac.cleanupCandidates.first?.lastUsedAt == Timestamp(rawValue: "2026-09-01T00:00:00Z")?.date)
        #expect(mac.cleanupCandidates[1].caution == "未 push のコミットがある")
        #expect(mac.cleanupCandidates[2].kind == .simulator)
        #expect(mac.cleanupScannedAt == Timestamp(rawValue: "2027-01-15T07:30:00Z")?.date)
        #expect(mac.cleanupUnreadable == ["~/Documents"])
        #expect(mac.cleanupWork == .finding)
        #expect(mac.cleanupResult == "1 件を消しました。1 件は消しませんでした（未 push のコミットがあるので消さなかった）")

        let removing = try await makeService(files: Self.askingEpic(extra: Self.cleanupFiles(scanned: true, pending: "remove"))).service
        #expect(try #require(try await removing.fetchSnapshot().mac("mac-mini")).cleanupWork == .removing)
        // 頼みを済ませれば、済ませていない頼みは無い
        let idle = try await makeService(files: Self.askingEpic(extra: Self.cleanupFiles(scanned: true))).service
        #expect(try #require(try await idle.fetchSnapshot().mac("mac-mini")).cleanupWork == nil)
        // 候補のファイルを読めなければ、探している途中とも済んだとも出さない
        var unreadable = Self.cleanupFiles(scanned: false, pending: "find")
        unreadable["cleanup/mac-mini/candidates.json"] = #"{"v":99}"#
        let broken = try await makeService(files: Self.askingEpic(extra: unreadable)).service.fetchSnapshot()
        let brokenMac = try #require(broken.mac("mac-mini"))
        #expect(brokenMac.cleanupWork == .unknown)
        // 頼みのファイルだけを読めないときも、探している途中とも済んだとも出さない（重ねて探すを送らない）
        var requestsBroken = Self.cleanupFiles(scanned: true)
        requestsBroken["cleanup/mac-mini/requests.json"] = #"{"v":99}"#
        let unknown = try await makeService(files: Self.askingEpic(extra: requestsBroken)).service.fetchSnapshot()
        #expect(try #require(unknown.mac("mac-mini")).cleanupWork == .unknown)
    }

    @Test
    func sendsFindAndRemoveWithScannedTime() async throws {
        // まだ探していない Mac は、探すことだけ送れる
        let fresh = try makeService(files: Self.askingEpic())
        _ = try await fresh.service.fetchSnapshot()
        #expect(fresh.service.supports(.findCleanupCandidates(macID: "mac-mini")))
        #expect(!fresh.service.supports(.cleanUp(macID: "mac-mini", candidateIDs: ["0123456789abcdef"])))
        #expect(!fresh.service.supports(.findCleanupCandidates(macID: "imac")))
        try await fresh.service.perform(.findCleanupCandidates(macID: "mac-mini"))
        let find = try await sentEnvelope(in: fresh.store, key: fresh.key)
        #expect(find.kind == FindCleanupCandidatesIntent.kind)
        #expect(find.repo == nil)
        #expect(try FindCleanupCandidatesIntent(envelope: find).mac.rawValue == "mac-mini")

        // 探した後は、選んだ候補の id と、探した時刻を送る
        let scanned = try makeService(files: Self.askingEpic(extra: Self.cleanupFiles(scanned: true)))
        _ = try await scanned.service.fetchSnapshot()
        try await scanned.service.perform(.cleanUp(macID: "mac-mini", candidateIDs: ["0123456789abcdef"]))
        let remove = try RemoveCleanupCandidatesIntent(envelope: try await sentEnvelope(in: scanned.store, key: scanned.key))
        #expect(remove.candidates == ["0123456789abcdef"])
        #expect(remove.scannedAt.rawValue == "2027-01-15T07:30:00Z")
    }

    /// 消す前の確かめの文は、ゴミ箱に移すものと、元に戻せない Simulator を分けて書く
    @Test
    func confirmationTellsTrashFromPermanentDeletion() {
        let clone = CleanupCandidate(id: "a", kind: .clone, name: "~/a", bytes: 1, caution: nil)
        let simulator = CleanupCandidate(id: "b", kind: .simulator, name: "iPhone", bytes: 1, caution: nil)
        let both = CleanupView.confirmation([clone, simulator], bytes: 2_000_000_000)
        #expect(both.contains("ゴミ箱に移します"))
        #expect(both.contains("Simulator は元に戻せません"))
        #expect(!CleanupView.confirmation([clone], bytes: 1).contains("Simulator"))
        #expect(!CleanupView.confirmation([simulator], bytes: 1).contains("ゴミ箱"))
    }
}
