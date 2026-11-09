import AskHubKeychain
import Foundation

/// git の credential helper（`askhub-commander git-credential get`・`askhub-worker git-credential get`）の応答。
/// GitHub のトークンを、引数や環境変数に置かずに git に渡す。
///
/// トークンは持ち主（organization・個人）ごとにあるので、git に `credential.useHttpPath=true` を渡し、
/// 問い合わせの `path`（`owner/repo.git`）の持ち主でトークンを選ぶ（`docs/renewal/security.md` の「トークン」）
public enum GitCredential {
    /// トークンを返せない理由（標準エラーに出す。git の失敗の文に入り、試行の記録で分かる）。トークンの値は含めない
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        /// 問い合わせに `path` が無い（`credential.useHttpPath=true` を渡していない）
        case missingPath
        case invalidOwner(String)
        case missingToken(owner: String)
        case keychain(SecretStoreError)

        public var description: String {
            switch self {
            case .missingPath: "問い合わせに path が無い（git に credential.useHttpPath=true を渡す）"
            case let .invalidOwner(path): "path（\(path)）から GitHub の持ち主を読めない"
            case let .missingToken(owner): "持ち主 \(owner) の GitHub のトークンが Keychain に無い（token \(owner) で入れる）"
            case let .keychain(error): "Keychain を読めない（\(error)）"
            }
        }
    }

    /// git から標準入力で受け取った問い合わせ（`key=value` の行）に答える。github.com の https のときだけ、
    /// `path` の持ち主のトークンを返す。ほかのホスト・操作には何も返さない（ほかの credential helper に任せる）
    public static func response(to request: String, operation: String, tokens: GitHubTokens) throws(Problem) -> String {
        guard operation == "get" else { return "" }
        var fields: [String: String] = [:]
        for line in request.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard fields["protocol"] == "https", fields["host"] == "github.com" else { return "" }
        guard let path = fields["path"], !path.isEmpty else { throw .missingPath }
        let owner = String(path.drop { $0 == "/" }.prefix { $0 != "/" })
        guard GitHubTokens.normalizedOwner(owner) != nil else { throw .invalidOwner(path) }
        let token: String?
        do {
            token = try tokens.token(for: owner)
        } catch {
            throw .keychain(error)
        }
        guard let token else { throw .missingToken(owner: owner) }
        return "username=x-access-token\npassword=\(token)\n"
    }

    /// git の `credential.helper` に書く値（パスに空白があっても動くよう、シェルのクォートで囲む）
    public static func helper(executable: URL) -> String {
        "!'\(executable.path.replacingOccurrences(of: "'", with: "'\\''"))' git-credential"
    }
}
