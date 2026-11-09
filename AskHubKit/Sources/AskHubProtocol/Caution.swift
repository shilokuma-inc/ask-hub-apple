import Foundation

/// 慎重に決めてほしい理由。クライアントは、その質問・判断を警告として出す（祝う演出をやめ、警告の帯を出す）。
///
/// 質問・判断を書く Claude が付ける。付けるのは、間違えると取り返しのつかない判断だけにする
public struct Caution: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// トークン・認証・権限・データをアプリの外に出す
        case security
        /// 個人のデータの扱い
        case privacy
        /// データの削除・移行・公開など、取り消せない
        case irreversible
        /// お金がかかる
        case cost
    }

    /// 理由の長さの上限（Unicode のコードポイントの数。JSON Schema の maxLength と同じ数え方）
    public static let maximumReasonLength = 500

    public var kind: Kind
    /// この判断で何に気をつけてほしいか
    public var reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    /// 決まりに合わない点
    var problems: [String] {
        (1...Self.maximumReasonLength).contains(reason.unicodeScalars.count) ? [] : ["caution.reason は 1〜\(Self.maximumReasonLength) 文字"]
    }
}
