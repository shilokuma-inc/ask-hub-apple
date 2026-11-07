import AskHubProtocol
@testable import AskHubPullRequests
import Foundation

/// テストで使う値と応答の形。トークンは本物ではない
enum Fixture {
    static let token = "test-token-not-real-0123456789"
    static let repository = RepositoryFullName(rawValue: "shilokuma-inc/ask-hub-apple")!
    static let now = Date(timeIntervalSince1970: 1_793_700_000)
    static let sha = String(repeating: "a", count: 40)
    static let otherSHA = String(repeating: "b", count: 40)

    static func client(_ transport: StubTransport) -> GitHubPullRequests {
        GitHubPullRequests(repository: repository, transport: transport, now: { now }, token: { token })
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// REST の PR の応答
    static func pull(
        _ number: Int,
        head: String = "feat/task-1",
        base: String = "epic/feature",
        sha: String = Fixture.sha,
        headRepo: String = "shilokuma-inc/ask-hub-apple",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "number": number,
            "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/pull/\(number)",
            "state": "open",
            "merged_at": NSNull(),
            "head": ["ref": head, "sha": sha, "repo": ["full_name": headRepo]],
            "base": ["ref": base, "sha": otherSHA, "repo": ["full_name": "shilokuma-inc/ask-hub-apple"]]
        ]
        object.merge(extra) { _, new in new }
        return object
    }

    /// 要求の本文を JSON として読む
    static func body(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// 要求の URL の問い合わせ
    static func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    /// 要求の URL のパス
    static func path(_ request: URLRequest?) -> String {
        request?.url?.path ?? ""
    }

    static func link(next: String) -> [String: String] {
        ["Link": "<\(next)>; rel=\"next\", <https://api.github.com/x?page=9>; rel=\"last\""]
    }
}
