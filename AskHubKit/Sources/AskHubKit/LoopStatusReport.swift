import Foundation

/// オーケストレーターが状態用の Issue（ラベル `loop-status`）の本文に書き出す、リポジトリのループの状態。
///
/// アプリは GitHub だけを見るので、Mac の中にしか無いループの状態をオーケストレーターがここに書き、アプリが読む。
/// 本文の先頭に機械が読める目印（JSON）を置き、続けて人が読める表を置く:
///
/// ```html
/// <!-- ask-hub:loop-status {"checkedAt":"2026-10-06T00:00:00Z","state":"running",...} -->
/// ```
///
/// 詳細は `docs/protocol.md` の「ループの状態」を参照。
/// public リポジトリでは誰でも読めるので、ローカルパス・ログの中身・PC 名は持たない
public struct LoopStatusReport: Sendable, Equatable, Codable {
    /// 状態用の Issue に付けるラベル
    public static let labelName = AskHubLabel.loopStatus.rawValue
    /// 状態用の Issue のタイトル
    public static let issueTitle = "【AskHub】ループの状態"
    /// 確認時刻を書き直す間隔（担当の印と同じ）
    public static let updateInterval = OrchestratorHeartbeat.updateInterval
    /// 確認時刻がこの時間より古ければ、担当 PC がいないとみなす（担当の印と同じ）
    public static let freshness = OrchestratorHeartbeat.freshness

    /// ループの状態の分類
    public enum State: String, Sendable, CaseIterable, Codable {
        /// ループが動いている（プロセスが生きている・state ファイルがある）
        case running
        /// 回答待ちのタスクだけが残っている（PR の ask が未回答）
        case waitingForAnswer = "waiting-for-answer"
        /// Claude の利用上限で待機している（`usageLimitedUntil` に解除の時刻）
        case usageLimited = "usage-limited"
        /// epic のタスクが残ったままループが止まっている（再開待ち・手で止めた）、
        /// または `ready-for-loop` の Discussion があるが、まだ起動していない
        case waitingToStart = "waiting-to-start"
        /// 異常終了し、自動の再開を諦めた
        case gaveUp = "gave-up"
        /// 全タスクが終わり、最終 PR のマージを待っている
        case completed
        /// ループが無い
        case noLoop = "no-loop"
        /// このアプリが知らない分類（新しいオーケストレーターが書いたもの）。書き出しには使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        /// 人が読む表に出す名前
        public var title: String {
            switch self {
            case .running: "実行中"
            case .waitingForAnswer: "回答待ち"
            case .usageLimited: "上限で待機中"
            case .waitingToStart: "開始待ち"
            case .gaveUp: "異常終了（再開を諦めた）"
            case .completed: "完了（最終 PR のマージ待ち）"
            case .noLoop: "ループなし"
            case .unknown: "不明"
            }
        }
    }

    /// 状態用の Issue を書いたもの
    public enum Writer: String, Sendable, CaseIterable, Codable {
        /// オーケストレーター。キーが無い目印（`writer` を足す前に書かれたもの）もこれとして読む
        case orchestrator
        /// 手で回しているループ（`manual-loop` の Discussion）
        case manual
        /// このアプリが知らない書き手。書き出しには使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        /// 人が読む表に出す名前
        public var title: String {
            switch self {
            case .orchestrator: "オーケストレーター"
            case .manual: "手動"
            case .unknown: "不明"
            }
        }
    }

    /// goal のチェックボックスから数えたタスクの進捗
    public struct Progress: Sendable, Equatable, Codable {
        /// 終わったタスク（`[x]`。保留で閉じたものを含む）
        public var completed: Int
        /// すべてのタスク
        public var total: Int

        public init(completed: Int, total: Int) {
            self.completed = completed
            self.total = total
        }

        /// 「5 / 12 タスク完了」
        public var text: String {
            "\(completed) / \(total) タスク完了"
        }
    }

    public var state: State
    /// 書いたもの。手動のあいだはオーケストレーターが書かない
    public var writer: Writer
    /// 統合ブランチ（例: `epic/loop-status`）。ループが無ければ `nil`
    public var epic: String?
    /// ゴール元の Discussion の番号。手で始めた epic など、記録が無ければ `nil`
    public var discussion: Int?
    public var progress: Progress?
    // 時刻は目印に秒までしか書かないので、読み戻した値と比べられるよう代入のたびに秒未満を切り捨てる
    // （`didSet` は init では呼ばれないので、init でも切り捨てる）

    /// ループが最後に動いた時刻（state ファイル・ログの更新時刻など）
    public var lastActivityAt: Date? {
        didSet { lastActivityAt = lastActivityAt.map(Self.wholeSeconds) }
    }
    /// 利用上限の解除の時刻（`usageLimited` のとき）
    public var usageLimitedUntil: Date? {
        didSet { usageLimitedUntil = usageLimitedUntil.map(Self.wholeSeconds) }
    }
    /// 書き手（`writer`）が最後に確かめた時刻。状態が変わらなくても `updateInterval` ごとに書き直す
    public var checkedAt: Date {
        didSet { checkedAt = Self.wholeSeconds(checkedAt) }
    }

    public init(
        state: State,
        writer: Writer = .orchestrator,
        epic: String? = nil,
        discussion: Int? = nil,
        progress: Progress? = nil,
        lastActivityAt: Date? = nil,
        usageLimitedUntil: Date? = nil,
        checkedAt: Date
    ) {
        self.state = state
        self.writer = writer
        self.epic = epic
        self.discussion = discussion
        self.progress = progress
        self.lastActivityAt = lastActivityAt.map(Self.wholeSeconds)
        self.usageLimitedUntil = usageLimitedUntil.map(Self.wholeSeconds)
        self.checkedAt = Self.wholeSeconds(checkedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case state, writer, epic, discussion, progress, lastActivityAt, usageLimitedUntil, checkedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try container.decode(State.self, forKey: .state),
            writer: try container.decodeIfPresent(Writer.self, forKey: .writer) ?? .orchestrator,
            epic: try container.decodeIfPresent(String.self, forKey: .epic),
            discussion: try container.decodeIfPresent(Int.self, forKey: .discussion),
            progress: try container.decodeIfPresent(Progress.self, forKey: .progress),
            lastActivityAt: try container.decodeIfPresent(Date.self, forKey: .lastActivityAt),
            usageLimitedUntil: try container.decodeIfPresent(Date.self, forKey: .usageLimitedUntil),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt)
        )
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// 確認時刻を除いて同じ状態か。違うときだけ本文を書き換え、同じなら `updateInterval` ごとに確認時刻だけ書き直す
    public func hasSameStatus(as other: Self) -> Bool {
        var other = other
        other.checkedAt = checkedAt
        return self == other
    }

    /// 担当 PC がいるか（確認時刻が `freshness` より新しいか）
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: checkedAt, now: now)
    }

    // MARK: - 本文

    private static let commentOpen = "<!--"
    private static let commentClose = "-->"
    private static let keyword = "ask-hub:loop-status"

    /// 状態用の Issue の本文。先頭に目印、続けて人が読める表を置く
    public var issueBody: String {
        var rows = [("状態", state.title), ("書き手", writer.title)]
        if let epic {
            rows.append(("epic", Self.tableCell(epic)))
        }
        if let discussion {
            rows.append(("ゴール元", "Discussion #\(discussion)"))
        }
        if let progress {
            rows.append(("進捗", progress.text))
        }
        if let lastActivityAt {
            rows.append(("最後の動き", lastActivityAt.formatted(.iso8601)))
        }
        if let usageLimitedUntil {
            rows.append(("上限の解除", usageLimitedUntil.formatted(.iso8601)))
        }
        rows.append(("確認時刻", checkedAt.formatted(.iso8601)))
        let table = rows.map { "| \($0.0) | \($0.1) |" }.joined(separator: "\n")
        return """
        \(marker)
        ## ループの状態

        \(writer == .manual ? "手で回しているループ" : "AskHub のオーケストレーター")が書き換える Issue です。編集・クローズしないでください。

        | 項目 | 値 |
        | --- | --- |
        \(table)

        """
    }

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

    /// 状態用の Issue の本文から状態を読む。目印が先頭に無い・形式が崩れていれば `nil`。
    /// author が信用できるかはここでは判定しない（`TrustedAuthors` を使う）
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
        // `ask-hub:loop-statuses` のような別の語を誤って拾わないよう、直後は空白に限る
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: Data(rest.utf8))
    }

    /// 表のセルに置けるよう、改行を空白にし `|` をエスケープする
    private static func tableCell(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
    }
}
