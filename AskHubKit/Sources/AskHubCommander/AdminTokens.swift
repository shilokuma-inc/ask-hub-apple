import AskHubKeychain
import Foundation

/// 司令塔が管理の操作（保護の設定・対象に加えるときの GitHub 側の準備）に使う、持ち主ごとの管理用のトークン
/// （`docs/renewal/security.md` の「管理用のトークン」）。
///
/// 要求のたびに Keychain から読む（`admin-token` で入れ直したら、次の操作から使う）。署名した人の意図の処理にだけ渡し、
/// git の credential helper・Claude のジョブ・ワーカーには渡さない。値はログ・URL・エラー・状態リポジトリに出さない
public struct AdminTokens: Sendable {
    private let read: @Sendable (String) throws -> String?

    public init(secrets: any SecretStore) {
        let tokens = GitHubAdminTokens(secrets: secrets)
        read = { try tokens.token(for: $0) }
    }

    /// 読み方を差し替える（テスト用）
    public init(read: @escaping @Sendable (_ owner: String) throws -> String?) {
        self.read = read
    }

    /// 持ち主の管理用のトークン。無い・読めないときは、操作を断る理由
    public func token(for owner: String) -> Result<String, AdminTokenProblem> {
        do {
            guard let token = try read(owner), !token.isEmpty else { return .failure(.missing(owner: owner)) }
            return .success(token)
        } catch {
            return .failure(.unreadable(owner: owner))
        }
    }
}

/// 管理用のトークンを使えない理由。人の意図を断る理由として、クライアントに出す（トークンの値は含めない）
public enum AdminTokenProblem: Error, Equatable, Sendable, CustomStringConvertible {
    /// その持ち主の管理用のトークンを置いていない
    case missing(owner: String)
    /// Keychain から読めない（Keychain の確認を拒否した・項目の形が違う）
    case unreadable(owner: String)

    public var description: String {
        switch self {
        case let .missing(owner):
            "\(owner) の管理用のトークンが無い（常時オンの Mac で askhub-commander admin-token \(owner) を流して入れる）"
        case let .unreadable(owner):
            "\(owner) の管理用のトークンを Keychain から読めない（常時オンの Mac で askhub-commander check を流して確かめる）"
        }
    }
}
