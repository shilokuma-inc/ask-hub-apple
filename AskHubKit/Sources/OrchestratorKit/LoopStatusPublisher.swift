import AskHubKit
import Foundation

/// 担当リポジトリの状態用の Issue（`loop-status`）。閉じたものも含む
public struct LoopStatusIssueRecord: Sendable, Equatable {
    public let number: Int
    /// 作った author。削除済みのアカウントなどで取れなければ `nil`
    public let author: String?
    public let isOpen: Bool
    public let updatedAt: Date
    public let body: String

    public init(number: Int, author: String?, isOpen: Bool, updatedAt: Date, body: String) {
        self.number = number
        self.author = author
        self.isOpen = isOpen
        self.updatedAt = updatedAt
        self.body = body
    }
}

/// 状態用の Issue に、いつ何を書くかを決める（副作用なし）。
///
/// 書いた内容を覚えておき、状態が変わったときだけ本文を書き換える。変わらなければ
/// `LoopStatusReport.updateInterval` ごとに確認時刻だけを書き直す（API の呼び出しを増やしすぎない）。
/// 手で回しているループ（書き手が `manual`）が確認時刻を `LoopStatusReport.freshness` 以内に書いていれば、書かない
public struct LoopStatusPublisher: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// 状態用の Issue がまだ無い（覚えていない）。一覧を取得して `adopt` してから決め直す
        case lookUp
        /// 状態用の Issue を作る
        case create(body: String)
        /// 本文を書き換える（閉じられていれば開き直す）
        case update(number: Int, body: String)
        /// 書かない
        case none
    }

    struct Entry: Sendable, Equatable {
        var number: Int?
        /// 最後に書いた（Issue から読んだ）状態。読めない・閉じていれば `nil`（次は必ず書く）
        var report: LoopStatusReport?
    }

    /// キーは担当リポジトリの `fullName` を小文字にしたもの
    private(set) var entries: [String: Entry] = [:]

    public init() {}

    public func action(repositoryKey key: String, report: LoopStatusReport, now: Date) -> Action {
        guard let entry = entries[key] else {
            return .lookUp
        }
        guard let number = entry.number else {
            return .create(body: report.issueBody)
        }
        if Self.isWrittenByManualLoop(entry.report, now: now) {
            return .none
        }
        if let previous = entry.report, previous.hasSameStatus(as: report),
           now.timeIntervalSince(previous.checkedAt) < LoopStatusReport.updateInterval {
            return .none
        }
        return .update(number: number, body: report.issueBody)
    }

    /// 手で回しているループが書いている（書き手が `manual` で、確認時刻が `LoopStatusReport.freshness` 以内）。
    /// 手で回すループが止まって確認時刻が古くなれば、オーケストレーターが書き直す
    public static func isWrittenByManualLoop(_ report: LoopStatusReport?, now: Date) -> Bool {
        guard let report, report.writer == .manual else {
            return false
        }
        return report.isAssigned(now: now)
    }

    /// 取得した状態用の Issue から、使うものを覚える。
    /// 信用する author が作ったもののうち、open なものの最も新しく更新されたもの、無ければ閉じたものの最も新しいもの（開き直して使う）
    public mutating func adopt(_ issues: [LoopStatusIssueRecord], repositoryKey key: String, trustedAuthors: TrustedAuthors) {
        let trusted = issues
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.isOpen ? 1 : 0, $0.updatedAt, $0.number) > ($1.isOpen ? 1 : 0, $1.updatedAt, $1.number) }
        guard let issue = trusted.first else {
            entries[key] = Entry(number: nil, report: nil)
            return
        }
        entries[key] = Entry(number: issue.number, report: issue.isOpen ? LoopStatusReport.parse(issue.body) : nil)
    }

    /// 書き終えた
    public mutating func recordWritten(_ report: LoopStatusReport, number: Int, repositoryKey key: String) {
        entries[key] = Entry(number: number, report: report)
    }

    /// 書けなかった。次のポーリングで一覧から取り直す（Issue が消された・移された場合に備える）
    public mutating func forget(repositoryKey key: String) {
        entries[key] = nil
    }
}
