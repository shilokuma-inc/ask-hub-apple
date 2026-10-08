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
    public var updatedAt: Date

    public init(
        id: String,
        kind: Kind,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.updatedAt = updatedAt
    }
}
