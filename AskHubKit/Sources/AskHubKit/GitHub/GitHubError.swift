/// GitHub API の呼び出しで起きるエラー。トークンの値は含めない
public enum GitHubError: Error, Equatable, Sendable {
    /// HTTP のレスポンスとして解釈できない、またはページングの情報が不正
    case invalidResponse
    /// 2xx 以外のステータス。`message` は GitHub が返したエラーの説明
    case http(status: Int, message: String?)
    /// レート制限に達し、再試行の上限を超えた。`retryAfter` は次に試せるまでの目安
    case rateLimited(retryAfter: Duration)
    /// GraphQL の `errors` に含まれていたメッセージ
    case graphQL(messages: [String])
}
