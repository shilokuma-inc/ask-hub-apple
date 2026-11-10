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

    /// 開けるまで読み終えない（開けた後は待たずに読み終える）
    actor GateStore: StateStore {
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var paths: [String] = []
        var started: Int { paths.count }

        func open() {
            isOpen = true
            gates.forEach { $0.resume() }
            gates.removeAll()
        }

        func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
            paths.append(path)
            if !isOpen { await withCheckedContinuation { gates.append($0) } }
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

    /// 読み取りも写しの読み取りも `probe` に送る
    struct SnapshottingStore: StateStore {
        let probe: ProbeStore

        func read(_ path: String) async throws(StateStoreError) -> StoredBlob? { try await probe.read(path) }

        func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? { nil }

        func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String { "" }

        func snapshot() async throws(StateStoreError) -> any StateStore { probe }
    }

    @Test func snapshotReadsShareLimit() async throws {
        let probe = ProbeStore()
        let store = ConcurrencyLimitedStore(SnapshottingStore(probe: probe), limit: 4)
        let snapshot = try await store.snapshot()
        let paths = (1...30).map { "file-\($0).json" }
        await withTaskGroup(of: Void.self) { group in
            for (index, path) in paths.enumerated() {
                let target: any StateStore = index.isMultiple(of: 2) ? store : snapshot
                group.addTask { _ = try? await target.read(path) }
            }
        }
        // 写しから読む要求も、元の置き場所と同じ上限の中で出す（合わせて上限を超えない）
        #expect(await probe.reads == 30)
        #expect(await probe.maxInFlight == 4)
    }

    /// `body` を `seconds` 秒まで待つ。終わらなければ nil（空きが返らないと待ち続けるので、テストを止めないように）
    static func within<Value: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> Value) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { try? await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = await group.next() else { return nil }
            return first
        }
    }

    @Test func passesResultsAndErrorsThrough() async throws {
        let store = ConcurrencyLimitedStore(ProbeStore(), limit: 1)
        #expect(try await store.read("a.json")?.data == Data("a.json".utf8))
        await #expect(throws: StateStoreError.notFound) { try await store.read("missing.json") }
        // 失敗した後も空きは返っている（上限 1 なので、返っていなければ次は読めない）
        #expect(await Self.within(seconds: 5) { try await store.read("b.json")?.sha } == "b.json")
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

    @Test func cancelledWaiterNeverRunsEvenIfSlotArrivesFirst() async throws {
        // 取り消しと空きの受け渡しが、どちらが先でも、取り消した要求は下の置き場所に出ない
        for round in 0..<30 {
            let gate = GateStore()
            let store = ConcurrencyLimitedStore(gate, limit: 1)
            let first = Task { try await store.read("first-\(round).json") }
            while await gate.started == 0 { await Task.yield() }
            let waiting = Task { try await store.read("waiting-\(round).json") }
            try await Task.sleep(for: .milliseconds(5))
            waiting.cancel()
            await gate.open()
            _ = try? await waiting.value
            _ = try await first.value
            #expect(await !gate.paths.contains("waiting-\(round).json"))
            // 返した空きで、次は読める
            #expect(await Self.within(seconds: 5) { try await store.read("after-\(round).json")?.sha } == "after-\(round).json")
        }
    }
}
