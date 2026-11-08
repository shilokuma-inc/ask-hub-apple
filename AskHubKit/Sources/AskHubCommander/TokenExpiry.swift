import AskHubProtocol
import AskHubStateStore
import Foundation

/// 持ち主ごとの GitHub の fine-grained token の期限を、GitHub の API の応答の見出し（`github-authentication-token-expiration`）から読む。
///
/// `/rate_limit` は REST の上限に数えられないので、生きている印を書くたび（10 分ごと）に持ち主ごとに 1 回呼ぶ。
/// 401 が返ったトークンは使えない（前に読んだ期限を過ぎていれば `expired`、そうでなければ `invalid`）。
/// つながらない・GitHub の障害のときは、前に読んだ期限のまま。トークンの値は `Authorization` にだけ入れ、ログ・URL・エラーに出さない
public actor GitHubTokenExpiry {
    /// 期限の見出しの名前（HTTP の見出しは大文字と小文字を区別しない）
    public static let header = "github-authentication-token-expiration"

    private let transport: any HTTPTransport
    private let apiBase: URL
    /// 持ち主ごとに、前に読んだ期限（期限の無いトークンは入れない）
    private var known: [String: Date] = [:]

    public init(transport: any HTTPTransport = GitHubURLSessionTransport(), apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    /// 持ち主のトークンの様子と期限。`token` は Keychain から読んだ値（形は確かめ済み）
    public func check(owner: String, token: String, now: Date) async -> SelfCheck.GitHubToken {
        var request = URLRequest(url: apiBase.appendingPathComponent("rate_limit"))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try? await transport.send(request).1
        let expiresAt = response?.value(forHTTPHeaderField: Self.header).flatMap(Self.parse)
        switch response?.statusCode {
        case 401?:
            // 期限切れ・取り消し・作り直しのどれか。前に読んだ期限を過ぎていれば期限切れとみなす
            let last = known[owner]
            return .init(owner: owner, state: last.map { $0 <= now } == true ? .expired : .invalid, expiresAt: last.map(Timestamp.init))
        case let status? where (200..<300).contains(status) || expiresAt != nil:
            // 見出しが無いのは、期限の無いトークン
            known[owner] = expiresAt
        default:
            // つながらない・GitHub の障害。前に読んだ期限のまま
            break
        }
        let last = known[owner]
        return .init(owner: owner, state: last.map { $0 <= now } == true ? .expired : .ok, expiresAt: last.map(Timestamp.init))
    }

    /// 見出しの値を読む。GitHub は `2027-10-23 12:25:03 UTC` の形で返す（`+0900` のような時差の形で返すこともある）
    public static func parse(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return try? Date(text, strategy: .iso8601)
    }
}

/// Claude の setup-token を入れた日。setup-token は作った日から 1 年使えるので、入れた日から 1 年を期限とみなす。
///
/// 値は Keychain にだけ置き、ここ（`MachinePaths.claudeTokenRecord`）には日付だけを書く。`setup`・`claude-token` で新しい値を入れたときに書き直す
public struct ClaudeTokenRecord: Codable, Equatable, Sendable {
    public var storedAt: Timestamp

    public init(storedAt: Timestamp) {
        self.storedAt = storedAt
    }

    /// 入れた日から 1 年
    public var expiresAt: Timestamp {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(byAdding: .year, value: 1, to: storedAt.date)
        return Timestamp(date ?? storedAt.date.addingTimeInterval(365 * 24 * 60 * 60))
    }

    /// 記録が無い（前の版で入れた）・読めなければ nil
    public static func load(from url: URL) -> Self? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
