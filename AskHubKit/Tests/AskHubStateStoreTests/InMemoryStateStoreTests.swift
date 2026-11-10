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
}
