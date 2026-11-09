import AskHubCommands
import AskHubProtocol
import Foundation

/// `claude -p --output-format json` の結果（最後に 1 つだけ出る `{"type":"result",…}`）のうち、使う欄
struct ClaudeResultMessage: Equatable {
    var subtype: String
    var isError: Bool
    /// 結果の本文。失敗したときは、その理由の文
    var result: String
    var sessionID: String?
    /// `--json-schema` で決めた形の結果。JSON の文字列のまま持ち、受け取る型で読む
    var structuredOutput: Data?
    var totalCostUsd: Double?
    /// 実際に使われたモデル（`modelUsage` のキー）
    var models: [String]
    var apiErrorStatus: Int?
    var turns: Int?

    /// 標準出力から読む。最後の行から順に、結果の形のものを探す
    init?(standardOutput: Data) {
        let lines = standardOutput.split(separator: UInt8(ascii: "\n")).reversed()
        let objects = lines.lazy.compactMap { line in (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] }
        guard let object = objects.first(where: { $0["type"] as? String == "result" }) else {
            return nil
        }
        subtype = object["subtype"] as? String ?? ""
        isError = object["is_error"] as? Bool ?? true
        result = object["result"] as? String ?? ""
        sessionID = object["session_id"] as? String
        structuredOutput = object["structured_output"].flatMap { value in
            value is NSNull ? nil : try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        totalCostUsd = (object["total_cost_usd"] as? NSNumber)?.doubleValue
        models = ((object["modelUsage"] as? [String: Any]) ?? [:]).keys.sorted()
        apiErrorStatus = (object["api_error_status"] as? NSNumber)?.intValue
        turns = (object["num_turns"] as? NSNumber)?.intValue
    }

    init(
        subtype: String,
        isError: Bool,
        result: String = "",
        sessionID: String? = nil,
        structuredOutput: Data? = nil,
        totalCostUsd: Double? = nil,
        models: [String] = [],
        apiErrorStatus: Int? = nil,
        turns: Int? = nil
    ) {
        self.subtype = subtype
        self.isError = isError
        self.result = result
        self.sessionID = sessionID
        self.structuredOutput = structuredOutput
        self.totalCostUsd = totalCostUsd
        self.models = models
        self.apiErrorStatus = apiErrorStatus
        self.turns = turns
    }

    var succeeded: Bool { !isError && subtype == "success" }
}

/// 失敗した呼び出しを、試行の失敗の区分に分ける（`docs/renewal/architecture.md` の「失敗の区分と既定の扱い」）
struct ClaudeFailureClassifier {
    /// 利用上限の解除の時刻（「resets 3:45pm」）を、どの時間帯で読むか
    var timeZone: TimeZone
    var now: Date
    /// 伏せる値（setup-token）
    var secrets: [String]

    func failure(for result: CommandResult, message: ClaudeResultMessage?, timeout: Duration) -> AttemptFailure {
        let text = [message?.result ?? "", Self.lossyText(result.standardError)].joined(separator: "\n")
        let excerpt = Redaction.excerpt(
            of: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.lossyText(result.standardOutput) : text,
            secrets: secrets
        )
        if result.timedOut {
            return AttemptFailure(failureClass: .timeout, message: "Claude の呼び出しが上限（\(timeout)）を超えた", logExcerpt: excerpt)
        }
        let lowered = text.lowercased()
        let status = message?.apiErrorStatus
        // サブスクリプションの利用上限は、文言か解除の時刻で見分ける。時刻の無い 429 は、一時的な混み合いとして下で扱う
        let reset = UsageLimitReset(timeZone: timeZone, now: now).date(in: text)
        if reset != nil || Self.usageLimitPhrases.contains(where: lowered.contains) {
            return AttemptFailure(
                failureClass: .usageLimit, message: "Claude の利用上限に達した", logExcerpt: excerpt, retryAt: reset.map(Timestamp.init)
            )
        }
        if status == 401 || status == 403 || Self.authPhrases.contains(where: lowered.contains) {
            return AttemptFailure(failureClass: .authExpired, message: "Claude の認証が切れている・正しくない", logExcerpt: excerpt)
        }
        if status == 429 || (status.map { (500...599).contains($0) } ?? false) || Self.outagePhrases.contains(where: lowered.contains) {
            return AttemptFailure(failureClass: .claudeOutage, message: "Claude の API につながらない・混み合っている", logExcerpt: excerpt)
        }
        let reason = message.map { "subtype: \($0.subtype)" } ?? "結果の JSON が無い（終了コード \(result.status)）"
        return AttemptFailure(failureClass: .unexpected, message: "Claude の呼び出しが失敗した（\(reason)）", logExcerpt: excerpt)
    }

    static let usageLimitPhrases = ["usage limit", "hit your session limit", "hit your weekly limit", "hit your limit"]
    static let authPhrases = [
        "oauth token has expired", "invalid api key", "invalid bearer token", "authentication_error", "please run /login", "not logged in"
    ]
    static let outagePhrases = [
        "overloaded", "api error: 5", "internal server error", "connection error", "econnreset", "enotfound", "fetch failed",
        "rate limit", "rate_limit"
    ]

    /// 出力を文字列にする。末尾だけを残した出力は文字の途中で切れることがあるので、壊れた部分を置き換えて読む
    static func lossyText(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }
}

/// 利用上限の文から、解除の時刻を読む
struct UsageLimitReset {
    var timeZone: TimeZone
    var now: Date

    /// 「…|1762246800」（UNIX 時刻）か「resets 3:45pm」「resets 3pm (Asia/Tokyo)」。読めなければ nil
    func date(in text: String) -> Date? {
        if let match = text.firstMatch(of: #/\|(\d{10})\b/#), let seconds = TimeInterval(match.1) {
            return Date(timeIntervalSince1970: seconds)
        }
        let pattern = #/(?i)resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([A-Za-z_]+/[A-Za-z_]+)\))?/#
        guard let match = text.firstMatch(of: pattern),
              let hour = Int(match.1), (1...12).contains(hour) else {
            return nil
        }
        let minute = match.2.flatMap { Int($0) } ?? 0
        let zone = match.4.flatMap { TimeZone(identifier: String($0)) } ?? timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour24 = hour % 12 + (match.3.lowercased() == "pm" ? 12 : 0)
        // 今日のその時刻が過ぎていれば、明日のその時刻
        guard let today = calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
