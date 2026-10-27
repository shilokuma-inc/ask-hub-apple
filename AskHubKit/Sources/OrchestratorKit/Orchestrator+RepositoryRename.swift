import Foundation

/// 担当リポジトリの移管・改名への追従（Issue #757）。
///
/// 設定が旧名のままだと、検索（依頼・`ready-for-loop` など）が新しい名前で返す Issue・Discussion が担当リポジトリのどれにも当たらず、
/// ログに何も出ないまま無視される。旧名への REST のリクエストも、リダイレクトで認証が外れて失敗し続ける
extension Orchestrator {
    /// 同じリポジトリの名前を確かめ直す間隔。移管・改名はまれなので、毎回のポーリングでは問い合わせない
    static let repositoryNameCheckInterval: TimeInterval = 10 * 60

    /// 担当リポジトリの今の名前を確かめ、移管・改名されていたら設定の名前を書き換えて読み直す
    func followRenamedRepositories() async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            if let last = repositoryNameChecks[key], current.timeIntervalSince(last) < Self.repositoryNameCheckInterval {
                continue
            }
            // 確かめられなくても（ネットワーク・削除済み・権限なし）今の名前のまま動き、次の間隔で確かめ直す
            repositoryNameChecks[key] = current
            guard let name = try? await github.currentName(of: repository.fullName),
                  // 設定の照合は大文字・小文字を区別しないので、それだけの違いは書き換えない
                  name.caseInsensitiveCompare(repository.fullName) != .orderedSame else {
                continue
            }
            rename(repository, to: name)
        }
    }

    private func rename(_ repository: RepositoryConfig, to newName: String) {
        let key = repository.fullName.lowercased()
        let moved = "\(repository.fullName) は \(newName) に移管・改名されています"
        guard config.repository(named: newName) == nil else {
            reportRenameProblem("\(moved)が、\(newName) が既に担当リポジトリにあるため、設定を書き換えません。設定を手で直してください", for: key)
            return
        }
        guard let configStore else {
            reportRenameProblem("\(moved)が、設定ファイルの場所が分からないため、書き換えられません。設定を手で直してください", for: key)
            return
        }
        do {
            try configStore.renameRepository(repository.fullName, to: newName)
        } catch {
            reportRenameProblem("\(moved)が、設定を書き換えられませんでした（次の確認で再試行します）: \(error)", for: key)
            return
        }
        repositoryRenameProblems[key] = nil
        // checkout の origin は旧名のままでも git はリダイレクトで動くので、書き換えない
        log("\(moved)。設定の担当リポジトリの名前を書き換えました")
        reloadConfig()
    }

    /// 追従できなかった理由をログに出す。前回と同じ理由なら出さない（直るまで確認のたびに同じことが起きる）
    private func reportRenameProblem(_ message: String, for key: String) {
        guard repositoryRenameProblems[key] != message else {
            return
        }
        repositoryRenameProblems[key] = message
        log(message)
    }
}
