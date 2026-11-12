import AskHubProtocol
import Foundation

/// 持ち主（organization・個人）ごとの GitHub の fine-grained token（`docs/renewal/security.md` の「トークン」）。ワーカーと司令塔で使う。
///
/// fine-grained token は 1 つの持ち主のリポジトリしか扱えないので、持ち主ごとに 1 つ作り、Keychain に持ち主の名前で置く。
/// 読む側はリポジトリの持ち主でトークンを選ぶ。値はログ・URL・エラーに出さない
public struct GitHubTokens: Sendable {
    public let secrets: any SecretStore
    private let shelf: OwnerTokenShelf

    public init(secrets: any SecretStore) {
        self.secrets = secrets
        shelf = OwnerTokenShelf(secrets: secrets, item: SecretItem.githubToken(normalizedOwner:))
    }

    /// fine-grained token の先頭（classic token は権限を絞れないので受け付けない）
    public static let prefix = "github_pat_"

    /// 持ち主のトークン。無ければ nil
    public func token(for owner: String) throws(SecretStoreError) -> String? {
        try shelf.token(for: owner)
    }

    /// 持ち主のトークンを置く（すでにあれば置き換える）。形を確かめてから呼ぶ（`problem(of:)`）
    public func store(_ token: String, for owner: String) throws(SecretStoreError) {
        try shelf.store(token, for: owner)
    }

    /// 持ち主のトークンがあるか
    public func contains(_ owner: String) throws(SecretStoreError) -> Bool {
        try shelf.contains(owner)
    }

    /// 自己診断に書く、持ち主たちのトークンの様子。1 つでも無ければ `missing`、形が違えば `invalid`。値そのものは書かない
    public func state(of owners: [String]) throws(SecretStoreError) -> SelfCheck.State {
        var state = SelfCheck.State.ok
        for owner in owners {
            switch try shelf.state(of: owner) {
            case .missing: return .missing
            case .invalid: state = .invalid
            case .ok, .expired: continue
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
}

/// 持ち主ごとの管理用の GitHub の fine-grained token（`docs/renewal/security.md` の「管理用のトークン」）。常時オンの Mac の司令塔だけが置く。
///
/// 保護の設定（ルールセット）・Discussions を有効にする・ワークフローのファイルを変える PR など、毎日のトークン（`GitHubTokens`）には
/// 持たせない権限（Administration・Workflows など）の操作に使う。使うのは、司令塔が署名した人の意図を処理するときだけ。
/// 毎日のトークンとは別の型と別の Keychain の名前にして、git の credential helper（`GitCredential`）・Claude のジョブ・ワーカーには渡さない。
/// 値はログ・URL・エラー・状態リポジトリに出さない
public struct GitHubAdminTokens: Sendable {
    public let secrets: any SecretStore
    private let shelf: OwnerTokenShelf

    public init(secrets: any SecretStore) {
        self.secrets = secrets
        shelf = OwnerTokenShelf(secrets: secrets, item: SecretItem.githubAdminToken(normalizedOwner:))
    }

    /// 持ち主の管理用のトークン。無ければ nil
    public func token(for owner: String) throws(SecretStoreError) -> String? {
        try shelf.token(for: owner)
    }

    /// 持ち主の管理用のトークンを置く（すでにあれば置き換える）。形を確かめてから呼ぶ（`GitHubTokens.problem(of:)`）
    public func store(_ token: String, for owner: String) throws(SecretStoreError) {
        try shelf.store(token, for: owner)
    }

    /// 持ち主の管理用のトークンがあるか
    public func contains(_ owner: String) throws(SecretStoreError) -> Bool {
        try shelf.contains(owner)
    }

    /// 自己診断に書く、持ち主の管理用のトークンの様子（`ok`・`missing`・`invalid`）。値そのものは書かない
    public func state(of owner: String) throws(SecretStoreError) -> SelfCheck.State {
        try shelf.state(of: owner)
    }
}

/// 持ち主の名前で Keychain に置くトークン（毎日のトークンと管理用のトークンで共通の読み書き）
private struct OwnerTokenShelf: Sendable {
    let secrets: any SecretStore
    /// そろえた持ち主の名前から、Keychain の名前を作る
    let item: @Sendable (String) -> SecretItem

    func token(for owner: String) throws(SecretStoreError) -> String? {
        guard let item = item(of: owner), let data = try secrets.read(item) else { return nil }
        guard let token = String(bytes: data, encoding: .utf8), !token.isEmpty else { throw .malformed(item) }
        return token
    }

    func store(_ token: String, for owner: String) throws(SecretStoreError) {
        guard let item = item(of: owner) else { throw .invalidOwner(owner) }
        try secrets.write(Data(token.utf8), for: item)
    }

    func contains(_ owner: String) throws(SecretStoreError) -> Bool {
        guard let item = item(of: owner) else { return false }
        return try secrets.read(item) != nil
    }

    /// 無ければ `missing`、fine-grained token の形でなければ `invalid`
    func state(of owner: String) throws(SecretStoreError) -> SelfCheck.State {
        guard let item = item(of: owner), let data = try secrets.read(item) else { return .missing }
        guard let token = String(bytes: data, encoding: .utf8), GitHubTokens.problem(of: token) == nil else { return .invalid }
        return .ok
    }

    private func item(of owner: String) -> SecretItem? {
        GitHubTokens.normalizedOwner(owner).map(item)
    }
}
