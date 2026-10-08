import AskHubKit
import Foundation

/// 担当リポジトリごとの信用する author。ポーリングのはじめに求めておき、その周回の判定ではこれを引く。
///
/// 設定の `trustedAuthors` はどのリポジトリでも信用する。`trustRepositoryWriters` が有効なら、
/// そのリポジトリに書き込み権限（write 以上）を持つアカウントも信用する（`docs/protocol.md` の「信用する author」）
public struct TrustDirectory: Sendable, Equatable {
    /// どのリポジトリでも信用する author（設定の一覧）
    public let base: TrustedAuthors
    /// キーは `owner/repo` を小文字にしたもの
    public let repositories: [String: TrustedAuthors]

    public init(base: TrustedAuthors, repositories: [String: TrustedAuthors] = [:]) {
        self.base = base
        self.repositories = repositories
    }

    /// `repository` で信用する author。求めていないリポジトリでは設定の一覧だけ
    public func authors(for repository: String) -> TrustedAuthors {
        repositories[repository.lowercased()] ?? base
    }

    /// 起動するコマンドに渡す、信用する author（`ASKHUB_TRUSTED_AUTHORS` の値。カンマ区切り）
    public func environmentValue(for repository: String) -> String {
        authors(for: repository).sortedLogins.joined(separator: ",")
    }
}
