@testable import AskHubKit
import Foundation
import Testing

struct GraphQLTests {
    private struct User: Decodable, Equatable {
        let login: String
    }

    private struct Viewer: Decodable, Equatable {
        let viewer: User
    }

    private func makeClient(_ http: MockHTTPClient) -> GitHubClient {
        GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
    }

    @Test func postsQueryAndVariablesAndDecodesData() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{"data":{"viewer":{"login":"mrs1669"}}}"#)])
        let result = try await makeClient(http).graphQL(
            "query($n: Int!) { viewer { login } }",
            variables: ["n": .int(1), "after": .null],
            as: Viewer.self
        )
        #expect(result == Viewer(viewer: User(login: "mrs1669")))
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["query"] as? String == "query($n: Int!) { viewer { login } }")
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["n"] as? Int == 1)
        #expect(variables["after"] is NSNull)
    }

    @Test func errorsAreThrown() async {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{"data":null,"errors":[{"message":"Could not resolve to a Repository"}]}"#)
        ])
        await #expect(throws: GitHubError.graphQL(messages: ["Could not resolve to a Repository"])) {
            try await makeClient(http).graphQL("query { viewer { login } }", as: Viewer.self)
        }
    }

    @Test func collectsAllPages() async throws {
        let pages: [String?: ([Int], GraphQLPageInfo)] = [
            nil: ([1, 2], GraphQLPageInfo(hasNextPage: true, endCursor: "c1")),
            "c1": ([3], GraphQLPageInfo(hasNextPage: true, endCursor: "c2")),
            "c2": ([4], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
        ]
        let items = try await collectGraphQLPages { after in
            let page = try #require(pages[after])
            return (items: page.0, pageInfo: page.1)
        }
        #expect(items == [1, 2, 3, 4])
    }

    @Test func stopsWhenCursorDoesNotAdvance() async {
        await #expect(throws: GitHubError.invalidResponse) {
            try await collectGraphQLPages { _ in
                (items: [1], pageInfo: GraphQLPageInfo(hasNextPage: true, endCursor: nil))
            }
        }
    }
}
