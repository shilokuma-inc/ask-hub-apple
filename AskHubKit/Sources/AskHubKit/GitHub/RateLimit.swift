import Foundation

/// レート制限に当たったときの再試行の方針
public struct RetryPolicy: Sendable, Equatable {
    /// 既定値。待ち時間が 60 秒以内なら、最大 3 回まで待って再試行する
    public static let `default` = Self(maxRetries: 3, maxWait: .seconds(60))

    /// 再試行の最大回数
    public var maxRetries: Int
    /// 1 回に待ってよい最大の時間。これより長く待つ必要があれば再試行せずにエラーにする
    public var maxWait: Duration

    public init(maxRetries: Int, maxWait: Duration) {
        self.maxRetries = maxRetries
        self.maxWait = maxWait
    }
}

enum RateLimit {
    /// セカンダリレート制限でヘッダーに待ち時間が無いときに待つ時間（GitHub のドキュメントの推奨）
    static let defaultSecondaryWait: Duration = .seconds(60)

    /// レート制限によるエラーなら、再試行までに待つ時間を返す。レート制限でなければ `nil`
    ///
    /// - 403 / 429 で `Retry-After` があれば、その秒数
    /// - 403 / 429 で `x-ratelimit-remaining` が 0 なら、`x-ratelimit-reset`（UNIX 時刻）まで
    /// - 429 でヘッダーが無ければ 60 秒
    /// - それ以外の 403 は権限のエラーとして扱う（レート制限ではない）
    static func waitDuration(for response: HTTPURLResponse, now: Date) -> Duration? {
        guard response.statusCode == 403 || response.statusCode == 429 else {
            return nil
        }
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) {
            return .seconds(max(retryAfter, 0))
        }
        if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
           let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
            let seconds = max(reset - now.timeIntervalSince1970, 0)
            // リセット時刻ちょうどではまだ弾かれることがあるため 1 秒余裕を持たせる
            return .seconds(Int(seconds.rounded(.up)) + 1)
        }
        return response.statusCode == 429 ? defaultSecondaryWait : nil
    }
}

enum LinkHeader {
    /// `Link` ヘッダーから `rel="next"` の URL を取り出す
    ///
    /// 例: `<https://api.github.com/repositories/1/issues?page=2>; rel="next", <…?page=5>; rel="last"`
    static func nextURL(from header: String?) -> URL? {
        guard let header else {
            return nil
        }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  parts.dropFirst().contains(#"rel="next""#) else {
                continue
            }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}
