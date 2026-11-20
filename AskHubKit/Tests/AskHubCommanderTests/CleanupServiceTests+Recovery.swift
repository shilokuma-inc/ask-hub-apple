@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 片付けの結果を書けなかった・止まった・頼みのファイルが壊れたときに、消したものを消し直さず、新しい結果を古い結果で上書きしない
extension CleanupServiceTests {
    /// 消す頼みを済ませて結果を書いた後、消している間の書き置き（途中で止まった）が手元に残ったことにする
    /// （結果を書いた直後に止まった・書き置きを消せなかった）
    func publishRemovalLeavingJournal(_ journal: URL) async throws {
        let finder = RecordingCleanupMachine(candidates: [Self.clean])
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        await run(CleanupService(context: context, machine: finder, journal: journal) { _ in })
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 2))
        let peeking = JournalPeekingMachine(journal: journal, candidates: [Self.clean])
        await run(CleanupService(context: context, machine: peeking, journal: journal) { _ in })
        #expect(try await candidates().handled.last?.removed == [Self.clean.id])
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        let written = try #require(peeking.journalWhileRemoving)
        try written.write(to: journal)
    }

    /// 結果を書いた後に書き置きが残っても、起動し直したときに書き置きで上書きしない
    @Test func keepsPublishedResultWhenJournalOutlivesIt() async throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        try await publishRemovalLeavingJournal(journal)
        let again = RecordingCleanupMachine(candidates: [Self.clean])
        let restarted = CleanupService(context: context, machine: again, journal: journal) { _ in }
        await run(restarted)
        await run(restarted)
        #expect(again.removed.isEmpty)
        let published = try await candidates()
        #expect(published.handled.last?.removed == [Self.clean.id])
        #expect(published.handled.last?.problem == nil)
        #expect(published.candidates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    /// 書き置きを消せない（0o555）・読めもしない（0o000）間は、次の頼みを済ませない（済ませた記録が上限で落ちた後に、古い書き置きで上書きしない）
    @Test(arguments: [0o555, 0o000])
    func waitsForJournalRemovalBeforeNextRequest(locked permissions: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writable = [FileAttributeKey.posixPermissions: 0o755]
        defer {
            try? FileManager.default.setAttributes(writable, ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let journal = folder.appendingPathComponent("cleanup-unpublished.json")
        try await publishRemovalLeavingJournal(journal)
        // 書き置きのフォルダを書けなく（消せなく）して、次の探す頼みを積む
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: folder.path)
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 3))
        let again = RecordingCleanupMachine(candidates: [Self.clean])
        let restarted = CleanupService(context: context, machine: again, journal: journal) { _ in }
        await run(restarted)
        await run(restarted)
        #expect(again.scans == 0)
        #expect(try await candidates().handled.last?.removed == [Self.clean.id])

        // 消せるようになれば、書き置きを消してから次の頼みを済ませる
        try FileManager.default.setAttributes(writable, ofItemAtPath: folder.path)
        await run(restarted)
        await run(restarted)
        #expect(again.scans == 1)
        #expect(try await candidates().handled.last?.action == .find)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }
    /// 形が違って読めない書き置きは、無いものとして扱わない（次の頼みを済ませない）。消えたら次の頼みを済ませる
    @Test func waitsWhileJournalCannotBeDecoded() async throws {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-journal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        try Data("{".utf8).write(to: journal)
        try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine, journal: journal) { _ in }
        await run(service)
        #expect(machine.scans == 0)
        try FileManager.default.removeItem(at: journal)
        await run(service)
        #expect(machine.scans == 1)
    }
    /// 同じ秒に探し直しても、探した時刻を変える。前に探したときの時刻で選んだ頼みでは、何も消さない
    @Test func findingAgainInSameSecondMovesScannedAt() async throws {
        let machine = RecordingCleanupMachine(candidates: [Self.clean])
        let service = CleanupService(context: context, machine: machine) { _ in }
        for nonce in [1, 2] {
            try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: nonce))
            await run(service)
        }
        #expect(try await candidates().scannedAt == Timestamp(Self.now.addingTimeInterval(1)))
        let payload: [String: JSONValue] = [
            "mac": .string(Self.mac.rawValue),
            "scannedAt": .string(Timestamp(Self.now).rawValue),
            "candidates": .array([.string(Self.clean.id)])
        ]
        try await accept(try await signed("removeCleanupCandidates", payload: payload, nonce: 3))
        await run(service)
        #expect(machine.removed.isEmpty)
        #expect(try await candidates().handled.last?.problem?.hasPrefix("選んだ後に探し直したので") == true)
    }

    /// 頼みのファイルの形が読めなければ、投げずに断る（ほかの意図と見回りを止めない）
    @Test func rejectsWhenRequestsFileIsUnreadable() async throws {
        await store.put(StatePath.cleanupRequests(Self.mac), data: Data(#"{"v":99}"#.utf8))
        let decision = try await accept(try await signed("findCleanupCandidates", payload: ["mac": .string(Self.mac.rawValue)], nonce: 1))
        guard case let .reject(reason) = decision else {
            Issue.record("断らなかった: \(decision)")
            return
        }
        #expect(reason.contains("片付けの頼みのファイル"))
    }
    /// 書き置きは状態リポジトリ・ブランチ・Mac ごとに分ける。同じ設定で起動し直せば同じ書き置きを読み、ブランチを変えれば前の書き置きを読まない
    @Test func journalNameSeparatesRepositoryBranchAndMac() throws {
        let repository = try #require(RepositoryFullName(rawValue: "o/askhub-state"))
        let other = try #require(RepositoryFullName(rawValue: "o/other-state"))
        let base = CleanupService.journalName(repository: repository, branch: nil, mac: Self.mac)
        #expect(base == CleanupService.journalName(repository: repository, branch: nil, mac: Self.mac))
        let names = [
            base,
            CleanupService.journalName(repository: repository, branch: "test/1", mac: Self.mac),
            CleanupService.journalName(repository: repository, branch: "test", mac: Self.mac),
            CleanupService.journalName(repository: other, branch: nil, mac: Self.mac),
            CleanupService.journalName(repository: repository, branch: nil, mac: Self.other)
        ]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("cleanup-unpublished-") && $0.hasSuffix(".json") && !$0.contains("/") })
    }
}
