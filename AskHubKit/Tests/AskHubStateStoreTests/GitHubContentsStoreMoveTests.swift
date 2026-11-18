import AskHubProtocol
@testable import AskHubStateStore
import Foundation
import Testing

/// ディレクトリをまとめて移す（Git Data API の 1 つのコミット）
extension GitHubContentsStoreTests {
    /// 移す流れの応答（ブランチの先頭・コミット・元の親の一覧・先の親と先が無い・元の下のファイル・tree・コミット）と、最後のブランチの更新
    private static func moveReplies(update: StubTransport.Reply) -> [StubTransport.Reply] {
        let listing = #"[{"type":"dir","name":"01JCJ0A0000000000000000001","#
            + #""path":"repos/o/r/epics/01JCJ0A0000000000000000001","sha":"aa01"}]"#
        let files = #"{"sha":"aa01","truncated":false,"tree":[{"path":"epic.json","mode":"100644","type":"blob","sha":"bb01"},"#
            + #"{"path":"jobs","mode":"040000","type":"tree","sha":"aa02"},"#
            + #"{"path":"jobs/j1.json","mode":"100644","type":"blob","sha":"bb02"}]}"#
        return [
            .json(200, #"{"object":{"sha":"cc01"}}"#),
            .json(200, #"{"tree":{"sha":"dd00"}}"#),
            .json(200, listing),
            .json(404, #"{"message":"Not Found"}"#),
            .json(404, #"{"message":"Not Found"}"#),
            .json(200, files),
            .json(201, #"{"sha":"dd01"}"#),
            .json(201, #"{"sha":"cc02"}"#),
            update
        ]
    }

    /// 要求の本文の JSON。読めなければ空
    private static func jsonBody(of request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static let epicMove = StateMove(
        from: "repos/o/r/epics/01JCJ0A0000000000000000001", to: "archive/repos/o/r/epics/01JCJ0A0000000000000000001"
    )

    /// 元の下のファイルを、同じ blob のまま先に置き、元を消す tree を 1 つのコミットにして、ブランチを早送りで進める。内容を作る要求だけを予算に数える
    @Test func movesDirectoriesInOneCommit() async throws {
        let transport = StubTransport(Self.moveReplies(update: .json(200, #"{"object":{"sha":"cc02"}}"#)))
        let budget = WriteBudget(limits: .init(perMinute: 4, perHour: 100))
        try await store(transport, branch: "main", budget: budget).move([Self.epicMove], message: "archive に移す")

        let requests = transport.requests
        try #require(requests.count == 9)
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /repos/shilokuma-inc/askhub-state/git/ref/heads/main",
            "GET /repos/shilokuma-inc/askhub-state/git/commits/cc01",
            "GET /repos/shilokuma-inc/askhub-state/contents/repos/o/r/epics",
            "GET /repos/shilokuma-inc/askhub-state/contents/archive/repos/o/r/epics",
            "GET /repos/shilokuma-inc/askhub-state/contents/archive/repos/o/r/epics/01JCJ0A0000000000000000001",
            "GET /repos/shilokuma-inc/askhub-state/git/trees/aa01",
            "POST /repos/shilokuma-inc/askhub-state/git/trees",
            "POST /repos/shilokuma-inc/askhub-state/git/commits",
            "PATCH /repos/shilokuma-inc/askhub-state/git/refs/heads/main"
        ])
        let tree = Self.jsonBody(of: requests[6])
        #expect(tree["base_tree"] as? String == "dd00")
        let entries = try #require(tree["tree"] as? [[String: Any]])
        try #require(entries.count == 4)
        let old = "repos/o/r/epics/01JCJ0A0000000000000000001"
        let new = "archive/" + old
        #expect(entries.map { "\($0["path"] as? String ?? "") \($0["sha"] as? String ?? "null") \($0["mode"] as? String ?? "")" } == [
            "\(old)/epic.json null 100644", "\(new)/epic.json bb01 100644",
            "\(old)/jobs/j1.json null 100644", "\(new)/jobs/j1.json bb02 100644"
        ])
        // 消すものは sha を null で送る（欄を省くと、消さずに残る）
        #expect(entries[0].keys.contains("sha") && entries[0]["sha"] is NSNull)
        let commit = Self.jsonBody(of: requests[7])
        #expect(commit["message"] as? String == "archive に移す")
        #expect(commit["tree"] as? String == "dd01")
        #expect(commit["parents"] as? [String] == ["cc01"])
        let update = Self.jsonBody(of: requests[8])
        #expect(update["sha"] as? String == "cc02")
        #expect(update["force"] as? Bool == false)
        // 1 分 4 件の予算のうち 3 件を使った（読み取りは数えない）
        try await budget.reserve(now: Self.now)
        await #expect(throws: StateStoreError.self) { try await budget.reserve(now: Self.now) }
    }

    /// 読んだ後にほかの書き手が書いて早送りにならなければ、`conflict`（読み直してやり直す）
    /// 早送りにならないときだけ `conflict` にし、ほかの 422（ルールで断られたなど）は理由ごと伝える
    @Test func otherUnprocessableUpdateKeepsItsReason() async throws {
        let rule = StubTransport.Reply.json(422, #"{"message":"Repository rule violations found"}"#)
        let transport = StubTransport(Self.moveReplies(update: rule))
        do {
            try await store(transport, branch: "main").move([Self.epicMove], message: "archive に移す")
            Issue.record("断られたのに移したことになった")
        } catch let .unexpected(status, message) {
            #expect(status == 422)
            #expect(message?.contains("Repository rule violations") == true)
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func moveIsConflictWhenBranchMoved() async throws {
        let transport = StubTransport(Self.moveReplies(update: .json(422, #"{"message":"Update is not a fast forward"}"#)))
        await #expect(throws: StateStoreError.conflict) {
            try await store(transport, branch: "main").move([Self.epicMove], message: "archive に移す")
        }
    }

    /// ブランチを決めていなければ、リポジトリの既定のブランチを読んで使う。移す元が無ければ何も書かない
    @Test func moveUsesDefaultBranchAndSkipsMissingSources() async throws {
        let transport = StubTransport([
            .json(200, #"{"default_branch":"release+stable/1"}"#),
            .json(200, #"{"object":{"sha":"cc01"}}"#),
            .json(200, #"{"tree":{"sha":"dd00"}}"#),
            .json(404, #"{"message":"Not Found"}"#)
        ])
        try await store(transport).move([Self.epicMove], message: "archive に移す")
        try #require(transport.requests.count == 4)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/repos/shilokuma-inc/askhub-state")
        // git の ref に使える `+` を含む既定のブランチも扱う（`+` と `/` はパスにそのまま使える）
        #expect(transport.requests[1].url?.path == "/repos/shilokuma-inc/askhub-state/git/ref/heads/release+stable/1")
    }
}
