import Foundation

/// 受信箱の「任意判断」「実機確認」に出す Issue（仮決め一覧・実機確認）
public struct InboxIssue: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// epic ごとの仮決め一覧（`decision-log`）
        case decisionLog
        /// 実機・実データでの確認（`needs-verify`）
        case needsVerify

        /// 「任意判断」「実機確認」に出すラベル
        public static let labels: [AskHubLabel] = [.decisionLog, .needsVerify]

        /// Issue のラベル名から種類を決める。両方付いていれば判断ログを優先する
        public init?(labelNames: [String]) {
            func has(_ label: AskHubLabel) -> Bool {
                labelNames.contains { $0.caseInsensitiveCompare(label.rawValue) == .orderedSame }
            }
            if has(.decisionLog) {
                self = .decisionLog
            } else if has(.needsVerify) {
                self = .needsVerify
            } else {
                return nil
            }
        }
    }

    /// GraphQL の node id
    public var id: String
    public var kind: Kind
    /// `owner/repo`
    public var repository: String
    public var number: Int
    public var title: String
    public var url: URL
    /// 削除済みのユーザーでは `nil`
    public var author: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// 本文（Markdown）
    public var body: String

    public init(
        id: String,
        kind: Kind,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        createdAt: Date,
        updatedAt: Date,
        body: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.body = body
    }

    /// 実機確認の本文の先頭にある目印（元の PR 番号と epic）。
    /// 仮決め一覧と、目印の無い Issue では `nil`（自由文からは推測しない）。
    /// 信用する author の Issue だけを扱うのは `InboxFetcher` の役割
    public var verifyMarker: VerifyMarker? {
        kind == .needsVerify ? VerifyMarker.parse(body) : nil
    }
}
