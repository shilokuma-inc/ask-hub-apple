import AskHubProtocol
@testable import AskHubStateStore
import Foundation
import os
import Testing

/// 本物の GitHub で、Contents API の振る舞いを確かめる。ふだん（CI を含む）は流さない。
///
/// 試験用のリポジトリとトークンを環境変数で渡したときだけ流す。トークンは表示しない:
/// `ASKHUB_LIVE_TEST_REPO=<owner/repo> ASKHUB_LIVE_TEST_TOKEN="$(gh auth token)" swift test --package-path AskHubKit --filter LiveGitHub`
/// 流すたびに `live-test/<UUID>/` の下にファイルを作る（消さない。試験用のリポジトリごと消す）
@Suite(.enabled(if: LiveTestEnvironment.isEnabled))
struct LiveGitHubContentsStoreTests {
    /// 応答の状態コードを残す
    final class RecordingTransport: HTTPTransport {
        private let inner = GitHubURLSessionTransport()
        private let state = OSAllocatedUnfairLock<[Int]>(initialState: [])

        var statuses: [Int] {
            state.withLock { $0 }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await inner.send(request)
            state.withLock { $0.append(response.statusCode) }
            return (data, response)
        }
    }

    @Test func behavesAsExpectedOnGitHub() async throws {
        let repository = try #require(LiveTestEnvironment.repository)
        let token = try #require(LiveTestEnvironment.token)
        let transport = RecordingTransport()
        let store = GitHubContentsStore(repository: repository, transport: transport, budget: nil) { token }
        let directory = "live-test/\(UUID().uuidString)"
        let path = "\(directory)/a.json"
        // base64 が 60 文字ごとに改行される長さにする
        let first = Data(String(repeating: "{\"v\":1}\n", count: 30).utf8)
        let second = Data("{\"v\":2}\n".utf8)

        #expect(try await store.read(path) == nil)
        let sha1 = try await store.write(path, data: first, replacing: nil, message: "[live-test] 作る")
        #expect(sha1 == InMemoryStateStore.sha(of: first))
        #expect(try await store.read(path) == StoredBlob(data: first, sha: sha1))
        // 変わっていなければ 304 が返り、前に読んだ中身を使う
        #expect(try await store.read(path) == StoredBlob(data: first, sha: sha1))
        #expect(transport.statuses.last == 304)
        // すでにあるファイルを版なしで書く（422）・古い版で書く（409）は、どちらもぶつかったとして断られる
        await #expect(throws: StateStoreError.conflict) {
            try await store.write(path, data: second, replacing: nil, message: "[live-test] もう一度作る")
        }
        await #expect(throws: StateStoreError.conflict) {
            try await store.write(path, data: second, replacing: "0000000000000000000000000000000000000000", message: "[live-test] 古い版")
        }
        let sha2 = try await store.write(path, data: second, replacing: sha1, message: "[live-test] 書き直す")
        #expect(try await store.read(path) == StoredBlob(data: second, sha: sha2))
        #expect(try await store.list(directory)?.map(\.name) == ["a.json"])
        #expect(try await store.list("\(directory)/missing") == nil)
        await #expect(throws: StateStoreError.wrongKind) { try await store.read(directory) }
    }
}

enum LiveTestEnvironment {
    static let repository = ProcessInfo.processInfo.environment["ASKHUB_LIVE_TEST_REPO"].flatMap(RepositoryFullName.init(rawValue:))
    static let token = ProcessInfo.processInfo.environment["ASKHUB_LIVE_TEST_TOKEN"]
    static let isEnabled = repository != nil && token != nil
}
