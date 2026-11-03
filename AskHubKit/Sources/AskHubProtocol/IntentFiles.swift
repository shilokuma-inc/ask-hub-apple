import Foundation

/// `consumed/<keyId>/<nonce>.json`（処理した人の意図の記録）。司令塔だけが書く。
///
/// 版なしで作る（すでにあれば断られる）ので、「まだ使われていないか」の確認と記録が 1 回の書き込みで済む。
/// 署名を確かめられた意図だけを記録する（署名の合わない意図の番号で記録を作ると、本物の意図を使えなくできてしまうため）
public struct ConsumedIntentFile: StateFile {
    public static let formatVersion = 1

    public enum Result: String, Codable, Sendable, CaseIterable {
        /// 指示として扱った
        case accepted
        /// 署名は合ったが、対象の版・有効期間などが合わず、指示として扱わなかった
        case rejected
    }

    public var kind: String
    public var consumedAt: Timestamp
    public var result: Result
    /// 扱わなかった理由。`rejected` のときだけ
    public var reason: String?

    public init(kind: String, consumedAt: Timestamp, result: Result, reason: String? = nil) {
        self.kind = kind
        self.consumedAt = consumedAt
        self.result = result
        self.reason = reason
    }

    public var violations: [String] {
        var violations: [String] = []
        if kind.isEmpty { violations.append("kind が空") }
        switch result {
        case .accepted where reason != nil:
            violations.append("accepted に reason がある")
        case .rejected where reason?.isEmpty ?? true:
            violations.append("rejected に reason が無い")
        default:
            break
        }
        return violations
    }
}
