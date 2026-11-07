import Foundation

/// GitHub の PR の操作の失敗。トークンの値は含めない
public enum PullRequestError: Error, Equatable, Sendable {
    /// トークンが無効か期限切れ（401）
    case unauthorized
    /// トークンを読めない（Keychain に無い・読めない）。GitHub には送っていない
    case tokenUnavailable
    /// 権限が無い（上限ではない 403）
    case forbidden(message: String?)
    /// 無い、または見えない（GitHub は権限の無い private のリポジトリにも 404 を返す）
    case notFound
    /// GitHub の状態とぶつかった（409）
    case conflict(message: String?)
    /// head が、渡した SHA から動いた。マージ（409）とブランチの削除で返す。読み直して確かめ直す
    case headChanged
    /// マージできない（405。コンフリクト・必須のチェックやレビューが足りない など）
    case notMergeable(message: String?)
    /// 中身が受け付けられない（422）
    case rejected(message: String?)
    /// GitHub の上限（一次・二次）。`retryAfter` は次に試せるまでの目安
    case rateLimited(retryAfter: Duration)
    /// GitHub の障害（5xx）
    case serverError(status: Int)
    /// 通信の失敗
    case transport(String)
    /// リダイレクト（リポジトリの移管・改名）。追うと `Authorization` が落ちるので追わない
    case redirected(status: Int)
    /// 応答の形が違う
    case malformed(String)
    /// 渡した値（ブランチ名・SHA・番号）の形が違う。GitHub には送っていない
    case invalidArgument(String)
    /// 想定外の応答
    case unexpected(status: Int, message: String?)
    /// 待っている間に取り消された
    case cancelled

    /// 2xx 以外の応答を、失敗の種類に分ける。
    ///
    /// 二次の上限は、ヘッダーの無い 403 で返ることがある。権限のエラーと取り違えないよう、本文の文言でも見分ける
    static func classify(_ response: HTTPURLResponse, body: Data, now: Date) -> Self {
        let status = response.statusCode
        let message = GitHubErrorBody.message(from: body)
        switch status {
        case 300..<400:
            return .redirected(status: status)
        case 401:
            return .unauthorized
        case 403, 429:
            if let wait = rateLimitWait(response, message: message, now: now) { return .rateLimited(retryAfter: wait) }
            return .forbidden(message: message)
        case 404:
            return .notFound
        case 405:
            return .notMergeable(message: message)
        case 409:
            return .conflict(message: message)
        case 422:
            return .rejected(message: message)
        case 500..<600:
            return .serverError(status: status)
        default:
            return .unexpected(status: status, message: message)
        }
    }

    /// 二次の上限でヘッダーに待ち時間が無いときに待つ時間（GitHub の文書の推奨）
    static let defaultSecondaryWait: Duration = .seconds(60)

    /// 上限の待ち時間。`Retry-After` を先に見て、無ければ一次の上限のリセットの時刻から決める
    static func rateLimitWait(_ response: HTTPURLResponse, message: String?, now: Date) -> Duration? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) {
            return .seconds(max(retryAfter, 0))
        }
        if let reset = resetWait(response, now: now) { return reset }
        if response.statusCode == 429 || message?.localizedCaseInsensitiveContains("secondary rate limit") == true {
            return defaultSecondaryWait
        }
        return nil
    }

    /// 一次の上限を使い切ったときの、リセットまでの時間。使い切っていなければ nil
    static func resetWait(_ response: HTTPURLResponse, now: Date) -> Duration? {
        guard response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
              let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) else { return nil }
        // リセットの時刻ちょうどではまだ弾かれることがあるので、1 秒の余裕を持たせる
        return .seconds(Int(max(reset - now.timeIntervalSince1970, 0).rounded(.up)) + 1)
    }
}

/// GitHub のエラーの応答の本文（`message` と、422 の `errors[].message`）
struct GitHubErrorBody: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let message: String?
    let errors: [Detail]?

    /// `message` に `errors[].message` を続けた文。読めなければ nil
    static func message(from body: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: body) else { return nil }
        let details = (decoded.errors ?? []).compactMap(\.message)
        let parts = [decoded.message].compactMap(\.self) + details
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }
}
