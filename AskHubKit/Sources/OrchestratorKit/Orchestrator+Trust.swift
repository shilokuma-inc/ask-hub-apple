import AskHubKit
import Foundation

/// 担当リポジトリごとの信用する author を求める
extension Orchestrator {
    /// 起動スクリプトに信用する author を渡す環境変数
    static let trustedAuthorsVariable = "ASKHUB_TRUSTED_AUTHORS"

    /// 毎回のポーリングのはじめに、設定を読み直し（担当リポジトリの移管・改名に追従し）、信用する author を求め直し、手動ループを取得する
    func preparePoll() async {
        reloadConfig()
        await followRenamedRepositories()
        await refreshTrust()
        manualLoops = await searchManualLoops()
        if let manualLoops {
            manualLoopNumbers = manualLoops
                .filter { trust.authors(for: $0.repository).contains($0.author) }
                .reduce(into: [:]) { $0[$1.repository.lowercased(), default: []].insert($1.number) }
        }
    }

    /// 設定の一覧に、担当リポジトリごとの書き込み権限を持つアカウントを加え直す。
    /// 取得できなかったリポジトリは、前回の結果（無ければ設定の一覧だけ）を使う。信用する author が変わったらログに出す
    func refreshTrust() async {
        let base = config.trustedAuthors
        var repositories: [String: TrustedAuthors] = [:]
        if config.trustsRepositoryWriters, let repositoryWriters {
            for repository in config.repositories {
                let writers = await repositoryWriters.writers(of: repository.fullName)
                repositories[repository.fullName.lowercased()] = writers.map { base.union($0) } ?? base
            }
        }
        let updated = TrustDirectory(base: base, repositories: repositories)
        guard updated != trust else {
            return
        }
        for repository in config.repositories {
            let before = trust.authors(for: repository.fullName).sortedLogins
            let after = updated.authors(for: repository.fullName).sortedLogins
            if before != after {
                log("\(repository.fullName) で信用する author: \(after.joined(separator: ", "))")
            }
        }
        trust = updated
    }

    /// ループを起動するときに渡す環境変数（このリポジトリで信用する author と、設定の claude のモデル・エフォート）
    func loopEnvironment(for repository: RepositoryConfig) -> [String: String] {
        config.claudeEnvironment.merging([Self.trustedAuthorsVariable: trust.environmentValue(for: repository.fullName)]) { _, new in new }
    }
}
