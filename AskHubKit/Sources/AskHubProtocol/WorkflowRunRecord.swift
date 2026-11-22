import Foundation

/// 司令塔が `workflow_dispatch` で起動した GitHub Actions の実行の記録（スクショの撮影・クリエイティブアセットの書き出し）。
/// 送る前に `dispatchedAt` を書き、起動の応答か起動した後の一覧で id が分かったら書く（`docs/renewal/store-screenshots.md` の「撮影の起動と見張り」）
public struct WorkflowRunRecord: Codable, Equatable, Sendable {
    /// run の id。起動の応答か、起動した後の一覧で分かる。分かるまでは nil
    public var id: Int?
    /// run の画面（`html_url`）
    public var url: String?
    /// 起動を送った時刻（送る前に書く。id が分からないまま時間がたてば送り直す）
    public var dispatchedAt: Timestamp
    /// GitHub の run の様子（`queued`・`in_progress`・`completed` など）。まだ読んでいなければ nil
    public var status: String?
    /// 終わった run の結論（`success`・`failure`・`cancelled` など）
    public var conclusion: String?
    /// 起動の前からあった、ブランチの `workflow_dispatch` の run の最大の id（無ければ 0）。id の分からない run を一覧から探すとき、
    /// これより新しい run だけを候補にする（起動の前に人が起動した run を取り違えない）
    public var after: Int?

    public init(
        id: Int? = nil,
        url: String? = nil,
        dispatchedAt: Timestamp,
        status: String? = nil,
        conclusion: String? = nil,
        after: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.dispatchedAt = dispatchedAt
        self.status = status
        self.conclusion = conclusion
        self.after = after
    }

    /// 終わった
    public var isCompleted: Bool { status == "completed" }

    /// 決まりに合わない点（`label` は記録の中の置き場所。理由の頭に付ける）
    func problems(label: String) -> [String] {
        var problems: [String] = []
        if let id, id <= 0 { problems.append("\(label) の id は 1 以上") }
        if let after, after < 0 { problems.append("\(label) の after は 0 以上") }
        if let url, !url.hasPrefix("https://github.com/") || url.count > 400 { problems.append("\(label) の url は GitHub の画面") }
        let words = [status, conclusion].compactMap(\.self)
        if !words.allSatisfy({ $0.wholeMatch(of: #/[a-z_]{1,40}/#) != nil }) {
            problems.append("\(label) の status・conclusion の形が違う")
        }
        return problems
    }
}
