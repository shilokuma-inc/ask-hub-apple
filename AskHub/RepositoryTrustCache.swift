import AskHubKit
import CryptoKit
import Foundation
import os

/// アプリ全体で共有する、リポジトリの書き込み権限の取得結果。
///
/// 受信箱・ループ・マージ待ちが同じトークンで同じリポジトリの権限を何度も取らないよう、1 つにまとめて覚える。
/// トークンが変わったら（別のアカウントになりうるので）捨てて取り直す。キーにはトークンの SHA-256 を使い、値そのものは持たない。
/// モデルの既定の引数（`@Sendable` のクロージャ）から呼ぶので、MainActor に隔離しない
nonisolated enum RepositoryTrustCache {
    private struct Entry {
        let fingerprint: String
        let writers: RepositoryWriters
    }

    private static let current = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    /// 設定の一覧（`TrustedAuthors.default`）に、そのリポジトリへの書き込み権限を持つアカウントを加えて信用する
    static func trust(token: String) -> any TrustedAuthorsResolving {
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let writers = current.withLock { entry in
            if let entry, entry.fingerprint == fingerprint {
                return entry.writers
            }
            let writers = RepositoryWriters(source: GitHubRepositoryWriters(client: GitHubClient(token: token)))
            entry = Entry(fingerprint: fingerprint, writers: writers)
            return writers
        }
        return RepositoryTrust(base: .default, writers: writers)
    }
}
