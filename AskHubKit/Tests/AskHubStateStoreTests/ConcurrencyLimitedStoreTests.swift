import AskHubStateStore
import Foundation
import Testing

/// 状態リポジトリへの同時の要求の上限
struct ConcurrencyLimitedStoreTests {
    /// 読むたびに少し待ち、同時に動いている数の最大を覚える
    actor ProbeStore: StateStore {
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var reads = 0

        func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            reads += 1
            try? await Task.sleep(for: .milliseconds(20))
            inFlight -= 1
            guard path != "missing.json" else { throw .notFound }
            return StoredBlob(data: Data(path.utf8), sha: path)
        }

        func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? { nil }

        func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String { "" }
    }

    /// 開けるまで読み終えない
    actor GateStore: StateStore {
        private var gates: [CheckedContinuation<Void, Never>] = []
        private(set) var started = 0

        func open() {
            gates.forEach { $0.resume() }
            gates.removeAll()
        }

        func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
            started += 1
            await withCheckedContinuation { gates.append($0) }
            return StoredBlob(data: Data(), sha: path)
        }

        func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? { nil }

        func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String { "" }
    }

    @Test func keepsConcurrentCallsWithinLimit() async throws {
        let probe = ProbeStore()
        let store = ConcurrencyLimitedStore(probe, limit: 4)
        let paths = (1...30).map { "file-\($0).json" }
        let read = await withTaskGroup(of: String?.self) { group in
            for path in paths {
                group.addTask { try? await store.read(path)?.sha }
            }
            var read: [String] = []
            for await sha in group { sha.map { read.append($0) } }
            return read
        }
        #expect(Set(read) == Set(paths))
        #expect(await probe.reads == 30)
        // 並んで動くが、上限を超えない
        #expect(await probe.maxInFlight == 4)
    }

    @Test func passesResultsAndErrorsThrough() async throws {
        let store = ConcurrencyLimitedStore(ProbeStore(), limit: 2)
        #expect(try await store.read("a.json")?.data == Data("a.json".utf8))
        await #expect(throws: StateStoreError.notFound) { try await store.read("missing.json") }
        // 失敗した後も空きは返っている
        #expect(try await store.read("b.json")?.sha == "b.json")
    }

    @Test func cancelledWaiterGivesUpWithoutTakingSlot() async throws {
        let gate = GateStore()
        let store = ConcurrencyLimitedStore(gate, limit: 1)
        let first = Task { try await store.read("first.json") }
        while await gate.started == 0 { await Task.yield() }
        // 空きを待っている間に取り消すと、待たずに cancelled で終える
        let waiting = Task { try await store.read("waiting.json") }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: StateStoreError.cancelled) { try await waiting.value }
        #expect(await gate.started == 1)
        await gate.open()
        #expect(try await first.value?.sha == "first.json")
        // 取り消したものは空きを持っていかないので、次はすぐ動く
        let next = Task { try await store.read("next.json") }
        while await gate.started < 2 { await Task.yield() }
        await gate.open()
        #expect(try await next.value?.sha == "next.json")
    }
}
