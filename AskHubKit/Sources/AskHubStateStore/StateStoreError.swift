import Foundation

/// 状態リポジトリの読み書きの失敗。トークンの値は含めない
public enum StateStoreError: Error, Equatable, Sendable {
    /// 版が合わない、または同じブランチへの書き込みがぶつかった。読み直してやり直す
    case conflict
    /// GitHub の上限（一次・二次）。`retryAfter` は次に試せるまでの目安
    case rateLimited(retryAfter: Duration)
    /// この書き手の書き込みの予算を使い切った。`retryAfter` は次に書けるまでの時間
    case budgetExhausted(retryAfter: Duration)
    /// トークンが無効か期限切れ（401）
    case unauthorized
    /// 権限が無い（上限ではない 403）
    case forbidden(message: String?)
    /// 書き込み先のリポジトリかブランチが無い、または見えない（GitHub は権限の無い private のリポジトリにも 404 を返す）
    case notFound
    /// リダイレクト（リポジトリの移管・改名）。追うと `Authorization` が落ちるので追わない
    case redirected(status: Int)
    /// GitHub の障害（5xx）
    case serverError(status: Int)
    /// 通信の失敗
    case transport(String)
    /// パスがファイルでなくディレクトリだった（またはその逆）
    case wrongKind
    /// パスの形が違う（`..`・空の部品・決まった文字以外）
    case invalidPath
    /// 想定外の応答
    case unexpected(status: Int, message: String?)
    /// 待っている間に取り消された
    case cancelled

    /// 2xx・304・404 以外の応答を、失敗の種類に分ける。
    ///
    /// 二次の上限は、ヘッダーの無い 403 で返ることがある。権限のエラーと取り違えないよう、本文の文言でも見分ける
    static func classify(_ response: HTTPURLResponse, body: Data, now: Date) -> Self {
        let status = response.statusCode
        let message = GitHubMessage.decode(body)
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
        case 409:
            return .conflict
        case 422 where message?.localizedCaseInsensitiveContains("sha") == true:
            // すでにあるファイルを、版を付けずに作ろうとした（"sha" wasn't supplied）。ほかの書き手が先に作った
            return .conflict
        case 500..<600:
            return .serverError(status: status)
        default:
            return .unexpected(status: status, message: message)
        }
    }

    /// 二次の上限でヘッダーに待ち時間が無いときに待つ時間（GitHub の文書の推奨）
    static let defaultSecondaryWait: Duration = .seconds(60)

    private static func rateLimitWait(_ response: HTTPURLResponse, message: String?, now: Date) -> Duration? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) {
            return .seconds(max(retryAfter, 0))
        }
        if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
           let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
            // リセットの時刻ちょうどではまだ弾かれることがあるので、1 秒の余裕を持たせる
            return .seconds(Int(max(reset - now.timeIntervalSince1970, 0).rounded(.up)) + 1)
        }
        if response.statusCode == 429 || message?.localizedCaseInsensitiveContains("secondary rate limit") == true {
            return defaultSecondaryWait
        }
        return nil
    }
}

/// GitHub のエラーの応答の `message`
private struct GitHubMessage: Decodable {
    let message: String?

    static func decode(_ body: Data) -> String? {
        (try? JSONDecoder().decode(Self.self, from: body))?.message
    }
}
