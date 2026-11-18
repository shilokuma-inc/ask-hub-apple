import AskHubStateStore
import Foundation
import Testing

struct InMemoryStateStoreTests {
    @Test func snapshotKeepsContentsAndRefusesWrites() async throws {
        let store = InMemoryStateStore(files: ["macs/mac-mini.json": Data("1".utf8)])
        let snapshot = try await store.snapshot()
        await store.put("macs/mac-mini.json", data: Data("2".utf8))
        await store.put("macs/mbp.json", data: Data("3".utf8))
        // GitHub の写しと同じく、作ったときの中身のまま、後の書き込みを映さない
        #expect(try await snapshot.read("macs/mac-mini.json")?.data == Data("1".utf8))
        #expect(try await snapshot.list("macs")?.map(\.name) == ["mac-mini.json"])
        let sha = try #require(try await snapshot.read("macs/mac-mini.json")?.sha)
        await #expect(throws: (any Error).self) {
            try await snapshot.write("macs/mac-mini.json", data: Data("4".utf8), replacing: sha, message: "m")
        }
        #expect(try await store.read("macs/mac-mini.json")?.data == Data("2".utf8))
    }

    /// ディレクトリの下をまとめて移す。移す元が無いものは飛ばし、移す先に何かあれば何も移さない。写しでは断る
    @Test func movesDirectoriesTogetherOrNotAtAll() async throws {
        let store = InMemoryStateStore(files: [
            "repos/o/r/epics/e1/epic.json": Data("1".utf8),
            "repos/o/r/epics/e1/jobs/j.json": Data("2".utf8),
            "repos/o/r/epics/e2/epic.json": Data("3".utf8),
            "archive/repos/o/r/epics/e2/epic.json": Data("old".utf8)
        ])
        let snapshot = try await store.snapshot()
        let first = StateMove(from: "repos/o/r/epics/e1", to: "archive/repos/o/r/epics/e1")
        let missing = StateMove(from: "repos/o/r/epics/e9", to: "archive/repos/o/r/epics/e9")
        let taken = StateMove(from: "repos/o/r/epics/e2", to: "archive/repos/o/r/epics/e2")
        await #expect(throws: StateStoreError.conflict) { try await store.move([first, taken], message: "m") }
        #expect(await store.data(at: "repos/o/r/epics/e1/epic.json") == Data("1".utf8))
        #expect(await store.writeCount == 0)

        try await store.move([first, missing], message: "m")
        #expect(await store.data(at: "repos/o/r/epics/e1/epic.json") == nil)
        #expect(await store.data(at: "archive/repos/o/r/epics/e1/epic.json") == Data("1".utf8))
        #expect(await store.data(at: "archive/repos/o/r/epics/e1/jobs/j.json") == Data("2".utf8))
        #expect(try await store.list("repos/o/r/epics")?.map(\.name) == ["e2"])
        #expect(await store.writeCount == 1)
        await #expect(throws: (any Error).self) { try await snapshot.move([taken], message: "m") }
    }
}
