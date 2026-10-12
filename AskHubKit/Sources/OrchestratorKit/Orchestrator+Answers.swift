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

    /// 担当リポジトリ（`fullName` の小文字）ごとの、この PC の自動ループの epic（制御用 worktree の `epic/` のブランチ）。
    ///
    /// ralph-kit が作業場所を Discussion ごとに分けるまでは、この PC で回す手動ループも制御用 worktree を使う。
    /// 手動ループのあるリポジトリでは、制御用 worktree の epic のゴール元が手動ループの Discussion のとき・記録が無いときは含めない
    /// （自動ループは起動スクリプトがゴール元を記録する）
    func automaticEpicBranches(in epics: [String: EpicSnapshot]) -> [String: String] {
        var branches: [String: String] = [:]
        for (key, epic) in epics {
            guard let branch = epic.branch, branch.hasPrefix("epic/") else {
                continue
            }
            if manualLoopRepositories.contains(key) {
                guard let discussion = epic.discussion, !isManualLoop(discussion, in: key) else {
                    continue
                }
            }
            branches[key] = branch
        }
        return branches
    }

    /// 手動ループ（`manual-loop`）の Discussion か。このポーリングで取得できていなければ、手動ループとみなす
    private func isManualLoop(_ discussion: Int, in repositoryKey: String) -> Bool {
        guard let manualLoops else {
            return true
        }
        return manualLoops.contains { $0.repository.lowercased() == repositoryKey && $0.number == discussion }
    }
}
