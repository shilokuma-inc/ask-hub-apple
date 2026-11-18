@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// 終わってから 30 日たった epic を、状態リポジトリの `archive/` に畳む見回り。状態リポジトリはメモリの上に置く
struct FinishedEpicArchiveTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60
    static let origin = IntentReference(keyId: KeyID(rawValue: String(repeating: "k", count: 43))!, nonce: id(9))

    static func id(_ number: Int) -> ULID {
        ULID(rawValue: "01JCJ0A00000000000000000\(String(format: "%02d", number))")!
    }

    let store = InMemoryStateStore()
    let logs = OSAllocatedUnfairLock<[String]>(initialState: [])

    func archive() -> FinishedEpicArchive {
        let context = CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
        return FinishedEpicArchive(context: context) { [logs] message in logs.withLock { $0.append(message) } }
    }

    /// epic と、その下のジョブを置く。`mergedAgo` があればその時刻にマージした記録を付け、epic の更新の時刻は `updatedAgo` 日前にする
    func put(_ number: Int, _ stage: EpicStage, updatedAgo: Double, mergedAgo: Double? = nil, origin: IntentReference? = nil) async throws {
        let time = { (days: Double) in Timestamp(Self.now.addingTimeInterval(-days * Self.day)) }
        let file = EpicFile(
            id: Self.id(number),
            repo: Self.repo,
            title: "epic \(number)",
            stage: stage,
            merge: mergedAgo.map { EpicFile.Merge(commit: String(repeating: "a", count: 40), at: time($0)) },
            origin: origin,
            createdAt: time(60),
            updatedAt: time(updatedAgo)
        )
        await store.put(StatePath.epic(Self.repo, Self.id(number)), data: try StateFileCoder.encode(file))
        let job = StatePath.epicDirectory(Self.repo, Self.id(number)) + "/jobs/01JCJ0B0000000000000000001.json"
        await store.put(job, data: Data("{}".utf8))
    }

    /// マージかやめてから 30 日たった epic だけを、依頼の添付と一緒に 1 回の書き込みで畳む。マージした epic は、マージの時刻から数える
    @Test func archivesEpicsFinishedThirtyDaysAgoInOneWrite() async throws {
        try await put(1, .merged, updatedAgo: 25, mergedAgo: 31, origin: Self.origin)
        try await put(2, .abandoned, updatedAgo: 30)
        try await put(3, .merged, updatedAgo: 31, mergedAgo: 29)
        try await put(4, .running, updatedAgo: 40)
        // 読めない（知らない版の）epic は畳まない
        await store.put(StatePath.epic(Self.repo, Self.id(5)), data: Data(#"{"v":99}"#.utf8))
        let attachment = StatePath.attachment(device: Self.origin.keyId, nonce: Self.origin.nonce, number: 1)
        await store.put(attachment, data: Data("png".utf8))
        let before = await store.writeCount

        await archive().run()

        #expect(await store.writeCount == before + 1)
        for number in [1, 2] {
            let folder = StatePath.epicDirectory(Self.repo, Self.id(number))
            #expect(await store.data(at: StatePath.epic(Self.repo, Self.id(number))) == nil)
            #expect(await store.data(at: StatePath.archived(StatePath.epic(Self.repo, Self.id(number)))) != nil)
            #expect(await store.data(at: StatePath.archived(folder + "/jobs/01JCJ0B0000000000000000001.json")) != nil)
        }
        #expect(await store.data(at: attachment) == nil)
        #expect(await store.data(at: StatePath.archived(attachment)) == Data("png".utf8))
        for number in [3, 4, 5] {
            #expect(await store.data(at: StatePath.epic(Self.repo, Self.id(number))) != nil)
        }
        #expect(logs.withLock { $0 } == [
            "終わってから 30 日たった epic を archive/ に畳んだ: \(Self.repo)/\(Self.id(1))・\(Self.repo)/\(Self.id(2))"
        ])

        // 畳むものが無ければ書かない
        await archive().run()
        #expect(await store.writeCount == before + 1)
    }

    /// 書けなければ何も移さず、次の見回りでやり直す
    @Test func leavesEverythingWhenMoveFails() async throws {
        try await put(1, .abandoned, updatedAgo: 31)
        await store.failNextWrites(with: [.conflict])
        await archive().run()
        #expect(await store.data(at: StatePath.epic(Self.repo, Self.id(1))) != nil)
        #expect(logs.withLock { $0 }.first?.hasPrefix("終わってから 30 日たった epic を archive/ に畳めなかった") == true)
        await archive().run()
        #expect(await store.data(at: StatePath.epic(Self.repo, Self.id(1))) == nil)
    }
}
