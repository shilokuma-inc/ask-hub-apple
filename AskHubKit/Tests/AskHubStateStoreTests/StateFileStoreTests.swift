import AskHubProtocol
@testable import AskHubStateStore
import Foundation
import Testing

struct StateFileStoreTests {
    private static let path = "repos/shilokuma-inc/askhub-sandbox/repo.json"

    private static func repository(epics: Int = 1) -> RepositoryFile {
        RepositoryFile(
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!,
            platform: .apple,
            maxConcurrentEpics: epics,
            addedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!
        )
    }

    private func files(_ memory: InMemoryStateStore, sleeper: RecordingSleeper = RecordingSleeper()) -> StateFileStore {
        StateFileStore(store: memory, sleeper: sleeper)
    }

    @Test func createsReadsAndRefusesToCreateTwice() async throws {
        let memory = InMemoryStateStore()
        let store = files(memory)
        let created = try await store.create(Self.repository(), at: Self.path, message: "対象に加える")
        let loaded = try #require(try await store.read(RepositoryFile.self, at: Self.path))
        #expect(loaded.file == Self.repository())
        #expect(loaded.sha == created.sha)
        await #expect(throws: StateFileStore.Failure.alreadyExists) {
            try await store.create(Self.repository(epics: 2), at: Self.path, message: "もう一度")
        }
        #expect(try await store.read(RepositoryFile.self, at: Self.path)?.file.maxConcurrentEpics == 1)
    }

    @Test func updateWritesOnlyWhenChanged() async throws {
        let memory = InMemoryStateStore()
        let store = files(memory)
        try await store.create(Self.repository(), at: Self.path, message: "作る")
        // 途中で値を変えても、false を返せば書かず、読んだままの中身を返す
        let unchanged = try await store.update(RepositoryFile.self, at: Self.path, message: "何もしない") { file in
            file.maxConcurrentEpics = 5
            return false
        }
        #expect(unchanged.file == Self.repository())
        #expect(await memory.writeCount == 1)
        let changed = try await store.update(RepositoryFile.self, at: Self.path, message: "2 本にする") { file in
            file.maxConcurrentEpics = 2
            return true
        }
        #expect(changed.file.maxConcurrentEpics == 2)
        #expect(changed.sha != unchanged.sha)
        #expect(await memory.writeCount == 2)
    }

    @Test func updateRereadsAndRetriesAfterConflicts() async throws {
        let memory = InMemoryStateStore()
        let sleeper = RecordingSleeper()
        let store = files(memory, sleeper: sleeper)
        try await store.create(Self.repository(), at: Self.path, message: "作る")
        await memory.failNextWrites(with: [.conflict, .conflict])
        let updated = try await store.update(RepositoryFile.self, at: Self.path, message: "2 本にする") { file in
            file.maxConcurrentEpics = 2
            return true
        }
        #expect(updated.file.maxConcurrentEpics == 2)
        // 1 秒・2 秒に、0〜1 秒のずれを足して待つ
        let waits = sleeper.waits
        #expect(waits.count == 2)
        #expect(waits.count == 2 && waits[0] >= .seconds(1) && waits[0] < .seconds(2))
        #expect(waits.count == 2 && waits[1] >= .seconds(2) && waits[1] < .seconds(3))
    }

    @Test func updateSeesTheOtherWritersChange() async throws {
        let memory = InMemoryStateStore()
        let store = files(memory)
        try await store.create(Self.repository(), at: Self.path, message: "作る")
        // 読んだ後にほかの書き手が書き換えると、版が合わずにやり直し、新しい中身に対して change をもう一度当てる
        await memory.writeBeforeNextWrite(Self.path, data: try StateFileCoder.encode(Self.repository(epics: 3)))
        var seen: [Int] = []
        let updated = try await store.update(RepositoryFile.self, at: Self.path, message: "1 本足す") { file in
            seen.append(file.maxConcurrentEpics)
            file.maxConcurrentEpics += 1
            return true
        }
        #expect(seen == [1, 3])
        #expect(updated.file.maxConcurrentEpics == 4)
    }

    @Test func givesUpAfterTooManyConflicts() async throws {
        let memory = InMemoryStateStore()
        let sleeper = RecordingSleeper()
        let store = files(memory, sleeper: sleeper)
        try await store.create(Self.repository(), at: Self.path, message: "作る")
        await memory.failNextWrites(with: Array(repeating: .conflict, count: 4))
        await #expect(throws: StateFileStore.Failure.tooManyConflicts) {
            try await store.update(RepositoryFile.self, at: Self.path, message: "m") { _ in true }
        }
        #expect(sleeper.waits.count == 3)
    }

    @Test func otherFailuresAreNotRetried() async throws {
        let memory = InMemoryStateStore()
        let sleeper = RecordingSleeper()
        let store = files(memory, sleeper: sleeper)
        try await store.create(Self.repository(), at: Self.path, message: "作る")
        await memory.failNextWrites(with: [.rateLimited(retryAfter: .seconds(60))])
        await #expect(throws: StateFileStore.Failure.store(.rateLimited(retryAfter: .seconds(60)))) {
            try await store.update(RepositoryFile.self, at: Self.path, message: "m") { _ in true }
        }
        #expect(sleeper.waits.isEmpty)
    }

    @Test func updateDoesNotCreateMissingFile() async throws {
        let memory = InMemoryStateStore()
        await #expect(throws: StateFileStore.Failure.notFound) {
            try await files(memory).update(RepositoryFile.self, at: Self.path, message: "m") { _ in true }
        }
        #expect(await memory.writeCount == 0)
    }

    @Test func unreadableFileIsNotOverwritten() async throws {
        let future = Data(#"{"v":2,"repo":"shilokuma-inc/askhub-sandbox"}"#.utf8)
        let memory = InMemoryStateStore(files: [Self.path: future])
        let store = files(memory)
        await #expect(throws: StateFileStore.Failure.unreadable(path: Self.path, .unsupportedVersion(2))) {
            try await store.update(RepositoryFile.self, at: Self.path, message: "m") { _ in true }
        }
        await #expect(throws: StateFileStore.Failure.unreadable(path: Self.path, .unsupportedVersion(2))) {
            try await store.read(RepositoryFile.self, at: Self.path)
        }
        #expect(await memory.data(at: Self.path) == future)
    }

    @Test func refusesToWriteInvalidFile() async throws {
        let memory = InMemoryStateStore()
        await #expect(throws: StateFileStore.Failure.invalidFile("malformed(\"maxConcurrentEpics は 1 以上\")")) {
            try await files(memory).create(Self.repository(epics: 0), at: Self.path, message: "m")
        }
        #expect(await memory.writeCount == 0)
    }

    @Test func createRetriesWhenTheBranchWasBusy() async throws {
        let memory = InMemoryStateStore()
        let sleeper = RecordingSleeper()
        // ファイルは無いのに 409（同じブランチへの並んだ書き込みとぶつかった）。読み直して無ければやり直す
        await memory.failNextWrites(with: [.conflict])
        try await files(memory, sleeper: sleeper).create(Self.repository(), at: Self.path, message: "作る")
        #expect(sleeper.waits.count == 1)
        #expect(await memory.writeCount == 1)
    }

    @Test func replaceDoesNotOverwriteUnreadableFile() async throws {
        let future = Data(#"{"v":2}"#.utf8)
        let memory = InMemoryStateStore(files: [Self.path: future])
        await #expect(throws: StateFileStore.Failure.unreadable(path: Self.path, .unsupportedVersion(2))) {
            try await files(memory).replace(Self.repository(), at: Self.path, message: "置き換える")
        }
        #expect(await memory.data(at: Self.path) == future)
    }

    @Test func replaceCreatesThenOverwrites() async throws {
        let memory = InMemoryStateStore()
        let store = files(memory)
        try await store.replace(Self.repository(), at: Self.path, message: "作る")
        await memory.failNextWrites(with: [.conflict])
        try await store.replace(Self.repository(epics: 2), at: Self.path, message: "置き換える")
        #expect(try await store.read(RepositoryFile.self, at: Self.path)?.file.maxConcurrentEpics == 2)
        #expect(await memory.writeCount == 2)
    }

    // MARK: - メモリーの中の状態リポジトリ

    @Test func inMemoryStoreBehavesLikeContentsAPI() async throws {
        let memory = InMemoryStateStore()
        let first = try await memory.write("a/b/1.json", data: Data("1".utf8), replacing: nil, message: "m")
        _ = try await memory.write("a/c.json", data: Data("2".utf8), replacing: nil, message: "m")
        await #expect(throws: StateStoreError.conflict) { try await memory.write("a/b/1.json", data: Data(), replacing: nil, message: "m") }
        await #expect(throws: StateStoreError.conflict) {
            try await memory.write("a/b/1.json", data: Data(), replacing: "old", message: "m")
        }
        _ = try await memory.write("a/b/1.json", data: Data("3".utf8), replacing: first, message: "m")
        #expect(try await memory.list("a")?.map(\.name) == ["b", "c.json"])
        #expect(try await memory.list("a")?.map(\.kind) == [.directory, .file])
        #expect(try await memory.list("x") == nil)
        await #expect(throws: StateStoreError.wrongKind) { try await memory.read("a/b") }
        // 同じ名前を、ファイルとディレクトリの両方には使えない（ファイルの下に書く・子のあるパスをファイルにする）
        await #expect(throws: StateStoreError.wrongKind) {
            try await memory.write("a/c.json/d.json", data: Data(), replacing: nil, message: "m")
        }
        await #expect(throws: StateStoreError.wrongKind) { try await memory.write("a/b", data: Data(), replacing: nil, message: "m") }
        // Git の blob の sha と同じ（`printf 'hello\n' | git hash-object --stdin`）
        #expect(InMemoryStateStore.sha(of: Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }
}
