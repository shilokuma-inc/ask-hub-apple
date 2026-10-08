import AskHubKit
import Foundation

/// 担当リポジトリごとの信用する author を求める
extension Orchestrator {
    /// 起動スクリプトに信用する author を渡す環境変数
    static let trustedAuthorsVariable = "ASKHUB_TRUSTED_AUTHORS"

    /// 毎回のポーリングのはじめに、設定を読み直し、信用する author を求め直し、手動ループを取得する
    func preparePoll() async {
        reloadConfig()
        await refreshTrust()
        manualLoops = await searchManualLoops()
        if let manualLoops {
            manualLoopRepositories = Set(manualLoops
                .filter { trust.authors(for: $0.repository).contains($0.author) }
                .map { $0.repository.lowercased() })
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

    /// ループを起動するときに渡す環境変数（このリポジトリで信用する author）
    func loopEnvironment(for repository: RepositoryConfig) -> [String: String] {
        [Self.trustedAuthorsVariable: trust.environmentValue(for: repository.fullName)]
    }
}
