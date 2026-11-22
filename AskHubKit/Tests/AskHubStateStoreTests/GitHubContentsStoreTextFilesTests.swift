@testable import AskHubStateStore
import Foundation
import Testing

/// テキストのファイルをまとめて書く（Git Data API の 1 つのコミット。App Store のスクショの見本）
extension GitHubContentsStoreTests {
    private static func body(of request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static let files = [
        "repos/o/r/store-screenshots/1.2.0/c/IPHONE/ja/2.b64": "/9j/AAAA",
        "repos/o/r/store-screenshots/1.2.0/c/IPHONE/ja/1.b64": "/9j/BBBB"
    ]

    /// 先頭の tree に中身を重ねた tree とコミットを作り、ブランチを早送りで進める。何枚でも、予算は内容を作る要求の 3 件だけ
    @Test func writesTextFilesInOneCommit() async throws {
        let transport = StubTransport([
            .json(200, #"{"object":{"sha":"cc01"}}"#),
            .json(200, #"{"tree":{"sha":"dd00"}}"#),
            .json(201, #"{"sha":"dd01"}"#),
            .json(201, #"{"sha":"cc02"}"#),
            .json(200, #"{"object":{"sha":"cc02"}}"#)
        ])
        let budget = WriteBudget(limits: .init(perMinute: 4, perHour: 100))
        try await store(transport, branch: "main", budget: budget).writeTextFiles(Self.files, message: "見本")

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /repos/shilokuma-inc/askhub-state/git/ref/heads/main",
            "GET /repos/shilokuma-inc/askhub-state/git/commits/cc01",
            "POST /repos/shilokuma-inc/askhub-state/git/trees",
            "POST /repos/shilokuma-inc/askhub-state/git/commits",
            "PATCH /repos/shilokuma-inc/askhub-state/git/refs/heads/main"
        ])
        let tree = Self.body(of: requests[2])
        #expect(tree["base_tree"] as? String == "dd00")
        let entries = try #require(tree["tree"] as? [[String: Any]])
        // パスの順に、中身（content）を渡す。GitHub が blob を作る
        #expect(entries.map { "\($0["path"] as? String ?? "") \($0["content"] as? String ?? "") \($0["mode"] as? String ?? "")" } == [
            "repos/o/r/store-screenshots/1.2.0/c/IPHONE/ja/1.b64 /9j/BBBB 100644",
            "repos/o/r/store-screenshots/1.2.0/c/IPHONE/ja/2.b64 /9j/AAAA 100644"
        ])
        let commit = Self.body(of: requests[3])
        #expect(commit["tree"] as? String == "dd01" && commit["parents"] as? [String] == ["cc01"])
        #expect(Self.body(of: requests[4])["force"] as? Bool == false)
        // 1 分 4 件の予算のうち 3 件を使った
        try await budget.reserve(now: Self.now)
        await #expect(throws: StateStoreError.self) { try await budget.reserve(now: Self.now) }
    }

    /// 読んだ後にほかの書き手が書いて早送りにならなければ、読み直してやり直す
    @Test func retriesWhenAnotherWriterMovedTheBranch() async throws {
        let replies: [StubTransport.Reply] = [
            .json(200, #"{"object":{"sha":"cc01"}}"#),
            .json(200, #"{"tree":{"sha":"dd00"}}"#),
            .json(201, #"{"sha":"dd01"}"#),
            .json(201, #"{"sha":"cc02"}"#),
            .json(422, #"{"message":"Update is not a fast forward"}"#),
            .json(200, #"{"object":{"sha":"cc09"}}"#),
            .json(200, #"{"tree":{"sha":"dd09"}}"#),
            .json(201, #"{"sha":"dd10"}"#),
            .json(201, #"{"sha":"cc10"}"#),
            .json(200, #"{"object":{"sha":"cc10"}}"#)
        ]
        let transport = StubTransport(replies)
        try await store(transport, branch: "main").writeTextFiles(Self.files, message: "見本")
        let requests = transport.requests
        #expect(requests.count == 10)
        #expect(Self.body(of: requests[8])["parents"] as? [String] == ["cc09"])
    }

    @Test func refusesUnsafePathsBeforeSending() async {
        let transport = StubTransport([])
        await #expect(throws: StateStoreError.invalidPath) {
            try await store(transport, branch: "main").writeTextFiles(["repos/../x.b64": "a"], message: "見本")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func splitsLargeFilesIntoTrees() {
        let big = String(repeating: "a", count: GitHubContentsStore.treeChunkBytes / 2)
        let chunks = GitHubContentsStore.chunks(["a": big, "b": big, "c": big, "d": "small"])
        #expect(chunks.map { $0.map(\.key) } == [["a"], ["b"], ["c", "d"]])
    }
}
