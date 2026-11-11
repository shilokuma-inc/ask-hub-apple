@testable import AskHub
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 対象のアプリのアイコン: repo.json の `icon` から出すこと、状態リポジトリから読んで端末にしまうこと
@MainActor
struct AppIconTests {
    static let repo = "example/sample-ios"
    static let path = "repos/\(repo)/icon.png"
    static let image = Data("png".utf8)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppIconTests-\(UUID().uuidString)")

    static func repositoryFile(icon: String? = nil) -> String {
        let tree = String(repeating: "a", count: 40)
        let field = icon.map {
            #","icon":{"source":"App/AppIcon.icon","sourceTree":"\#(tree)","image":"\#($0)","updatedAt":"2026-11-11T00:00:00Z"}"#
        } ?? ""
        return #"{"v":1,"repo":"\#(repo)","platform":"apple","maxConcurrentEpics":1,"protection":{},"#
            + #""addedAt":"2026-11-01T00:00:00Z"\#(field)}"#
    }

    /// 状態リポジトリに置いたときの blob の sha
    static func sha(of data: Data) async throws -> String {
        try #require(try await InMemoryStateStore(files: ["file": data]).read("file")).sha
    }

    func makeService(files: [String: Data]) throws -> (StateClientService, RecordingReads) {
        let store = RecordingReads(base: InMemoryStateStore(files: files))
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        return (StateClientService(store: store, key: key, appIconCache: AppIconCache(directory: directory)), store)
    }

    @Test func showsStoredIconOnlyWhenCommanderWroteIt() async throws {
        let sha = try await Self.sha(of: Self.image)
        let (service, _) = try makeService(files: [
            "repos/\(Self.repo)/repo.json": Data(Self.repositoryFile(icon: sha).utf8),
            "repos/example/plain-ios/repo.json": Data(Self.repositoryFile().replacingOccurrences(of: "sample-ios", with: "plain-ios").utf8)
        ])
        let snapshot = try await service.fetchSnapshot()
        let icons = Dictionary(uniqueKeysWithValues: snapshot.repositories.map { ($0.fullName, $0.icon) })
        #expect(icons[Self.repo] == .stored(path: Self.path, version: sha))
        #expect(icons["example/plain-ios"] == .monogram)
    }

    @Test func readsIconOnceAndKeepsItOnDevice() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let sha = try await Self.sha(of: Self.image)
        let (service, store) = try makeService(files: [Self.path: Self.image])
        #expect(try await service.appIcon(at: Self.path, version: sha) == Self.image)
        #expect(try await service.appIcon(at: Self.path, version: sha) == Self.image)
        #expect(await store.reads(of: Self.path) == 1)

        // 起動し直しても、端末にしまったものを使う
        let (again, againStore) = try makeService(files: [Self.path: Self.image])
        #expect(try await again.appIcon(at: Self.path, version: sha) == Self.image)
        #expect(await againStore.reads(of: Self.path) == 0)
    }

    @Test func doesNotKeepImageOfAnotherVersion() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // repo.json が指す版と、読んだ画像の版が違う（画像を書き直している途中）
        let expected = String(repeating: "b", count: 40)
        let (service, store) = try makeService(files: [Self.path: Self.image])
        #expect(try await service.appIcon(at: Self.path, version: expected) == Self.image)
        #expect(try await service.appIcon(at: Self.path, version: expected) == Self.image)
        #expect(await store.reads(of: Self.path) == 2)
        #expect(AppIconCache(directory: directory).data(for: expected) == nil)
    }

    @Test func refusesOtherPathsAndMissingImage() async throws {
        let sha = String(repeating: "c", count: 40)
        let (service, _) = try makeService(files: ["repos/example/sample-ios/repo.json": Data()])
        await #expect(throws: ClientServiceError.self) { try await service.appIcon(at: "repos/example/sample-ios/repo.json", version: sha) }
        await #expect(throws: ClientServiceError.self) { try await service.appIcon(at: "repos/example/../icon.png", version: sha) }
        await #expect(throws: ClientServiceError(message: "アプリのアイコンが状態リポジトリに無い")) {
            try await service.appIcon(at: Self.path, version: sha)
        }
        #expect(StateClientService.isAppIconPath(Self.path))
        #expect(!StateClientService.isAppIconPath("repos/example/sample-ios/epics/icon.png"))
    }

    @Test func cacheUsesOnlyObjectIDsAsFileNames() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppIconCache(directory: directory)
        cache.store(Self.image, for: "../outside")
        #expect(cache.data(for: "../outside") == nil)
        let sha = String(repeating: "d", count: 40)
        cache.store(Self.image, for: sha)
        #expect(cache.data(for: sha) == Self.image)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sha).png").path))
    }
}

/// 読んだパスを数える状態リポジトリ
actor RecordingReads: StateStore {
    let base: InMemoryStateStore
    private var reads: [String] = []

    init(base: InMemoryStateStore) {
        self.base = base
    }

    func reads(of path: String) -> Int {
        reads.filter { $0 == path }.count
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        reads.append(path)
        return try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await base.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await base.write(path, data: data, replacing: sha, message: message)
    }
}
