import AskHubProtocol
import Foundation

/// 持ち主（organization・個人）ごとの GitHub の fine-grained token（`docs/renewal/security.md` の「トークン」）。ワーカーと司令塔で使う。
///
/// fine-grained token は 1 つの持ち主のリポジトリしか扱えないので、持ち主ごとに 1 つ作り、Keychain に持ち主の名前で置く。
/// 読む側はリポジトリの持ち主でトークンを選ぶ。値はログ・URL・エラーに出さない
public struct GitHubTokens: Sendable {
    public let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// fine-grained token の先頭（classic token は権限を絞れないので受け付けない）
    public static let prefix = "github_pat_"

    /// 持ち主のトークン。無ければ nil
    public func token(for owner: String) throws(SecretStoreError) -> String? {
        guard let item = Self.item(for: owner), let data = try secrets.read(item) else { return nil }
        guard let token = String(bytes: data, encoding: .utf8), !token.isEmpty else { throw .malformed(item) }
        return token
    }

    /// 持ち主のトークンを置く（すでにあれば置き換える）。形を確かめてから呼ぶ（`problem(of:)`）
    public func store(_ token: String, for owner: String) throws(SecretStoreError) {
        guard let item = Self.item(for: owner) else { throw .invalidOwner(owner) }
        try secrets.write(Data(token.utf8), for: item)
    }

    /// 持ち主のトークンがあるか
    public func contains(_ owner: String) throws(SecretStoreError) -> Bool {
        guard let item = Self.item(for: owner) else { return false }
        return try secrets.read(item) != nil
    }

    /// 自己診断に書く、持ち主たちのトークンの様子。1 つでも無ければ `missing`、形が違えば `invalid`。値そのものは書かない
    public func state(of owners: [String]) throws(SecretStoreError) -> SelfCheck.State {
        var state = SelfCheck.State.ok
        for owner in owners {
            guard let item = Self.item(for: owner), let data = try secrets.read(item) else { return .missing }
            guard let token = String(bytes: data, encoding: .utf8), Self.problem(of: token) == nil else {
                state = .invalid
                continue
            }
        }
        return state
    }

    /// 貼られたトークンの問題。fine-grained token の形なら nil
    public static func problem(of token: String) -> String? {
        if token.hasPrefix("ghp_") { return "classic token（ghp_）は権限を絞れないので使わない。fine-grained token（github_pat_ で始まる）を貼る" }
        guard token.hasPrefix(prefix), token.count > prefix.count else { return "fine-grained token（github_pat_ で始まる）の形でない" }
        guard token.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return "トークンに空白や英数字以外の文字が入っている"
        }
        return nil
    }

    /// Keychain の名前に使う持ち主の名前。GitHub の持ち主の名前（英数字とハイフンで 1〜39 文字。ハイフンで始まらない）でなければ nil。
    /// GitHub は大文字と小文字を区別しないので、小文字にそろえる
    public static func normalizedOwner(_ owner: String) -> String? {
        let isAllowed = { (scalar: Unicode.Scalar) in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
        guard (1...39).contains(owner.unicodeScalars.count), !owner.hasPrefix("-"), owner.unicodeScalars.allSatisfy(isAllowed) else {
            return nil
        }
        return owner.lowercased()
    }

    private static func item(for owner: String) -> SecretItem? {
        normalizedOwner(owner).map { .githubToken(normalizedOwner: $0) }
    }
}
