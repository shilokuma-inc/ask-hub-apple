import AskHubKit

// 回答の後処理。質問がすべて回答された Discussion / PR のラベルを付け替える
extension Orchestrator {
    /// 質問がすべて回答された Discussion / PR の後処理。
    /// 手で回す Discussion（`manual-loop`）では `addsReadyLabel` を `false` にし、ループを始めない
    func handleFullyAnswered(_ subject: InboxSubject, addsReadyLabel: Bool) async {
        let name = "\(subject.repository)#\(subject.number)"
        // Discussion（※1）の質問がすべて回答されたら、ループを始める（Discussion #1 の Q3 の変更）。
        // ready-for-loop を付けられなければ needs-answer も外さず、次のポーリングで再試行する
        // （先に外すと、この Discussion が回答待ちの検索に出なくなり、二度と付け直せない）
        if subject.kind == .discussion && !addsReadyLabel {
            log("\(name) は manual-loop（手で回す）なので、ready-for-loop は付けません")
        } else if subject.kind == .discussion {
            do {
                try await github.addReadyLabel(to: subject)
                log("\(name) の質問がすべて回答されたので、ready-for-loop を付けました（ループを始めます）")
            } catch {
                log("\(name) に ready-for-loop を付けられませんでした（次のポーリングで再試行します）: \(error)")
                return
            }
        }
        do {
            try await github.removeNeedsAnswerLabel(from: subject)
            log("\(name) の質問がすべて回答済みになったので、needs-answer を外しました")
        } catch {
            log("\(name) の needs-answer を外せませんでした（次のポーリングで再試行します）: \(error)")
        }
    }
}
