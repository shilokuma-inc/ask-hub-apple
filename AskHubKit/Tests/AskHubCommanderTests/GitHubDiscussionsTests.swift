@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// 決まった順に応答を返し、受けた要求を残す
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Self {
            Self(status: status, headers: headers, body: Data(text.utf8))
        }

        static func data(_ text: String) -> Self {
            json(200, #"{"data":\#(text)}"#)
        }
    }

    private let state: OSAllocatedUnfairLock<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) {
        state = OSAllocatedUnfairLock(initialState: (replies, []))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    /// 送った要求の本文（`query` と `variables`）
    var bodies: [JSONValue] {
        requests.compactMap { $0.httpBody.flatMap { try? JSONValue(parsing: $0) } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (reply.body, response)
    }
}

/// GitHub の GraphQL で Discussion を読み書きする
struct GitHubDiscussionsTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    func client(
        _ transport: StubTransport,
        budget: WriteBudget? = nil,
        token: @escaping @Sendable () async throws -> String = { "t0ken" }
    ) -> GitHubDiscussions {
        GitHubDiscussions(transport: transport, budget: budget, now: { Self.now }, token: token)
    }

    static func post(_ id: String, _ body: String = "", mine: Bool = true) -> String {
        #"{"id":"\#(id)","body":"\#(body)","viewerDidAuthor":\#(mine)}"#
    }

    static func page(_ nodes: [String], next: String? = nil) -> String {
        let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
        return #"{"pageInfo":\#(info),"nodes":[\#(nodes.joined(separator: ","))]}"#
    }

    @Test func readsRepositoryWithBearerToken() async throws {
        let fields = #""id":"R_1","hasDiscussionsEnabled":true,"discussionCategories":{"nodes":[{"id":"C_1","name":"Ideas"},null]}"#
        let transport = StubTransport([.data(#"{"repository":{\#(fields)}}"#)])
        let repository = try await client(transport).repository(Self.repo)
        #expect(repository == DiscussionRepository(id: "R_1", discussionsEnabled: true, categories: [.init(id: "C_1", name: "Ideas")]))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        // トークンは URL にも本文にも入れない
        #expect(request.url?.absoluteString.contains("t0ken") == false)
        #expect(String(bytes: request.httpBody ?? Data(), encoding: .utf8)?.contains("t0ken") == false)
        #expect(transport.bodies.first?["variables"] == .object(["owner": .string("shilokuma-inc"), "name": .string("askhub-sandbox")]))
    }

    @Test func followsCommentPagesAndReplies() async throws {
        func comment(_ id: String, mine: Bool, replies: String) -> String {
            #"{"id":"\#(id)","body":"","viewerDidAuthor":\#(mine),"replies":\#(replies)}"#
        }
        let first = Self.page([comment("C1", mine: true, replies: Self.page([Self.post("R1")], next: "r1"))], next: "c1")
        let second = Self.page([comment("C2", mine: false, replies: Self.page([]))])
        func discussion(_ comments: String) -> StubTransport.Reply {
            let fields = #""id":"D_1","number":7,"title":"題","body":"本文","viewerDidAuthor":true,"closed":true"#
            return .data(#"{"repository":{"discussion":{\#(fields),"comments":\#(comments)}}}"#)
        }
        let transport = StubTransport([
            discussion(first),
            .data(#"{"node":{"replies":\#(Self.page([Self.post("R2")]))}}"#),
            discussion(second)
        ])
        let thread = try #require(try await client(transport).discussion(Self.repo, number: 7))
        #expect(thread.id == "D_1")
        #expect(thread.closed)
        #expect(thread.comments.map(\.post.id) == ["C1", "C2"])
        #expect(thread.comments.map { $0.replies.map(\.id) } == [["R1", "R2"], []])
        #expect(thread.comments.map(\.post.viewerDidAuthor) == [true, false])
        let variables = transport.bodies.map { $0["variables"] }
        #expect(variables[1] == .object(["id": .string("C1"), "after": .string("r1")]))
        #expect(variables[2]?["after"] == .string("c1"))
        #expect(variables[2]?["number"] == .integer(7))
    }

    @Test func missingDiscussionIsNil() async throws {
        let errors = #"[{"type":"NOT_FOUND","message":"Could not resolve to a Discussion with the number of 9."}]"#
        let transport = StubTransport([.json(200, #"{"data":{"repository":{"discussion":null}},"errors":\#(errors)}"#)])
        #expect(try await client(transport).discussion(Self.repo, number: 9) == nil)
    }

    @Test func listsDiscussionsUntilSince() async throws {
        func node(_ number: Int, _ time: String) -> String {
            #"{"id":"D_\#(number)","number":\#(number),"body":"","createdAt":"\#(time)","viewerDidAuthor":true}"#
        }
        func list(_ page: String) -> StubTransport.Reply {
            .data(#"{"repository":{"discussions":\#(page)}}"#)
        }
        let transport = StubTransport([
            list(Self.page([node(9, "2026-11-07T10:00:00Z")], next: "p1")),
            list(Self.page([node(8, "2026-11-07T09:00:00Z"), node(7, "2026-11-06T00:00:00Z")], next: "p2"))
        ])
        let since = try Date("2026-11-07T00:00:00Z", strategy: .iso8601)
        let found = try await client(transport).discussions(Self.repo, createdSince: since)
        #expect(found.map(\.number) == [9, 8])
        // 古いものが出たページで止め、続きを読まない
        #expect(transport.requests.count == 2)
    }

    @Test func reportsMissingNodes() async throws {
        let errors = #"[{"type":"NOT_FOUND","message":"Could not resolve to a node with the global id of 'B'"}]"#
        let transport = StubTransport([.json(200, #"{"data":{"nodes":[{"id":"A"},null]},"errors":\#(errors)}"#)])
        #expect(try await client(transport).missing(["A", "B"]) == ["B"])
        #expect(try await client(StubTransport([])).missing([]).isEmpty)
    }

    @Test func mutationsSendInputAndCountInBudget() async throws {
        let transport = StubTransport([
            .data(#"{"createDiscussion":{"discussion":{"id":"D_1","number":12}}}"#),
            .data(#"{"addDiscussionComment":{"comment":{"id":"DC_1"}}}"#)
        ])
        let client = client(transport, budget: WriteBudget(limits: .init(perMinute: 2, perHour: 10)))
        let created = try await client.createDiscussion(repository: "R_1", category: "C_1", title: "題", body: "本文")
        #expect(created.number == 12)
        #expect(try await client.addComment(to: "D_1", replyingTo: "DC_0", body: "返信") == "DC_1")
        #expect(transport.bodies[1]["variables"]?["replyTo"] == .string("DC_0"))
        // 予算を使い切ったら、送らずに断る
        do {
            try await client.updateComment("DC_1", body: "直す")
            Issue.record("断っていない")
        } catch {
            guard case .http(.budgetExhausted) = error else { Issue.record("\(error)"); return }
        }
        #expect(transport.requests.count == 2)
    }

    @Test func closesDiscussionWithReason() async throws {
        let transport = StubTransport([.data(#"{"closeDiscussion":{"discussion":{"id":"D_1"}}}"#)])
        try await client(transport).closeDiscussion("D_1", reason: .resolved)
        #expect(transport.bodies[0]["variables"] == .object(["id": .string("D_1"), "reason": .string("RESOLVED")]))
        // 権限が足りないなどで payload が null なら、閉じられていない
        let refused = StubTransport([.data(#"{"closeDiscussion":null}"#)])
        do {
            try await client(refused).closeDiscussion("D_1", reason: .outdated)
            Issue.record("断っていない")
        } catch {
            guard case .malformed = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func classifiesFailures() async throws {
        let cases: [(StubTransport.Reply, FailureClass)] = [
            (.json(200, #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#), .githubOutage),
            (.json(403, #"{"message":"You have exceeded a secondary rate limit."}"#), .githubOutage),
            (.json(401, #"{"message":"Bad credentials"}"#), .authExpired),
            (.json(502, ""), .githubOutage),
            (.json(200, #"{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}"#), .unexpected),
            (.json(200, "<html>"), .githubOutage)
        ]
        for (reply, expected) in cases {
            do {
                _ = try await client(StubTransport([reply])).repository(Self.repo)
                Issue.record("失敗にしていない（\(reply.status)）")
            } catch {
                let failure = error.attemptFailure(now: Self.now)
                #expect(failure.failureClass == expected, "\(error)")
                #expect(!failure.message.contains("t0ken"))
            }
        }
    }

    @Test func doesNotSendWithoutToken() async throws {
        let transport = StubTransport([])
        do {
            _ = try await client(transport, token: { throw CancellationError() }).repository(Self.repo)
            Issue.record("送ってしまった")
        } catch {
            #expect(error == .http(.cancelled))
        }
        do {
            _ = try await client(transport, token: { throw URLError(.userAuthenticationRequired) }).repository(Self.repo)
            Issue.record("送ってしまった")
        } catch {
            #expect(error == .http(.tokenUnavailable))
            #expect(error.attemptFailure(now: Self.now).failureClass == .authExpired)
        }
        #expect(transport.requests.isEmpty)
    }
}
