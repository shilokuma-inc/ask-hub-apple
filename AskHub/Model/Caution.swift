import Foundation

/// 慎重に決めてほしい判断の理由。まとめて判断するでは、その札を警告ふうに出す（祝う演出をやめ、表の上に警告の帯を出す）。
///
/// 本番では Claude が質問や判断を書くときに付ける想定（プロトコルへの追加はまだ。いまはデモのデータだけ）
enum Caution: Hashable {
    /// セキュリティ（トークン・認証・権限・データをアプリの外に出す）
    case security
    /// 個人のデータの扱い
    case privacy
    /// 取り消せない変更（データの削除・移行・公開）
    case irreversible
    /// お金がかかる
    case cost

    var label: String {
        switch self {
        case .security: "セキュリティ"
        case .privacy: "個人のデータ"
        case .irreversible: "取り消せない"
        case .cost: "お金がかかる"
        }
    }

    var systemImage: String {
        switch self {
        case .security: "lock.shield.fill"
        case .privacy: "hand.raised.fill"
        case .irreversible: "exclamationmark.triangle.fill"
        case .cost: "yensign.circle.fill"
        }
    }
}
