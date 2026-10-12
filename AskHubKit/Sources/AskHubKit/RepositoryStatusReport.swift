import Foundation

/// オーケストレーターが状態用の Issue（ラベル `loop-status`）の本文に書く、リポジトリ全体の状態（本文の新しい形）。
///
/// ループの状態は本文ではなく、ループ（Discussion）ごとのコメントに `LoopStatusReport` の目印で書く（`LoopStatusBoard`）。
/// 本文には、ループに依らないリポジトリの状態（担当 PC の確認時刻・利用上限）だけを置く。
/// 目印は古い形の本文（`ask-hub:loop-status` の目印 1 つ）と別の語にして、どちらの形かを見分ける:
///
/// ```html
/// <!-- ask-hub:repository-status {"checkedAt":"2026-10-12T00:00:00Z","usageLimitedUntil":"2026-10-12T03:00:00Z"} -->
/// ```
///
/// 詳細は `docs/protocol.md` の「ループの状態」を参照
public struct RepositoryStatusReport: Sendable, Equatable, Codable {
    // 時刻は目印に秒までしか書かないので、読み戻した値と比べられるよう代入のたびに秒未満を切り捨てる
    // （`didSet` は init では呼ばれないので、init でも切り捨てる）

    /// Claude の利用上限の解除の時刻。上限で待機していなければ `nil`
    public var usageLimitedUntil: Date? {
        didSet { usageLimitedUntil = usageLimitedUntil.map(LoopStatusReport.wholeSeconds) }
    }
    /// オーケストレーターが最後に確かめた時刻。状態が変わらなくても `LoopStatusReport.updateInterval` ごとに書き直す
    public var checkedAt: Date {
        didSet { checkedAt = LoopStatusReport.wholeSeconds(checkedAt) }
    }

    public init(usageLimitedUntil: Date? = nil, checkedAt: Date) {
        self.usageLimitedUntil = usageLimitedUntil.map(LoopStatusReport.wholeSeconds)
        self.checkedAt = LoopStatusReport.wholeSeconds(checkedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case usageLimitedUntil, checkedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usageLimitedUntil: try container.decodeIfPresent(Date.self, forKey: .usageLimitedUntil),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt)
        )
    }

    /// 担当 PC がいるか（確認時刻が `LoopStatusReport.freshness` より新しいか）
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: checkedAt, now: now)
    }

    // MARK: - 本文

    private static let commentOpen = "<!--"
    private static let commentClose = "-->"
    private static let keyword = "ask-hub:repository-status"

    /// 本文の先頭に置く目印
    var marker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // 自分の型の値だけなのでエンコードは失敗しない
        let encoded = (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        // JSON の構文に `>` は無く、文字列の中にしか現れない。エスケープして目印の終わり（`-->`）と取り違えないようにする
        let json = encoded.replacingOccurrences(of: ">", with: "\\u003e")
        return "\(Self.commentOpen) \(Self.keyword) \(json) \(Self.commentClose)"
    }

    /// 状態用の Issue の本文からリポジトリ全体の状態を読む。目印が先頭に無い・形式が崩れていれば `nil`
    /// （古い形の本文（`ask-hub:loop-status`）も `nil`。`LoopStatusReport.parse` で読む）。
    /// author が信用できるかはここでは判定しない
    public static func parse(_ body: String) -> Self? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix(commentOpen), let closeRange = trimmed.range(of: commentClose) else {
            return nil
        }
        let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: commentOpen.count)..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix(keyword) else {
            return nil
        }
        let rest = inner.dropFirst(keyword.count)
        // 別の語を誤って拾わないよう、直後は空白に限る
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: Data(rest.utf8))
    }
}
