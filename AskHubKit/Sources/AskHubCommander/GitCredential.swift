import Foundation

/// git の credential helper（`askhub-commander git-credential get`）の応答。GitHub のトークンを、引数や環境変数に置かずに git に渡す
public enum GitCredential {
    /// git から標準入力で受け取った問い合わせ（`key=value` の行）に答える。github.com の https のときだけトークンを返し、ほかは何も返さない
    public static func response(to request: String, operation: String, token: () throws -> String?) rethrows -> String {
        guard operation == "get" else { return "" }
        var fields: [String: String] = [:]
        for line in request.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard fields["protocol"] == "https", fields["host"] == "github.com", let token = try token(), !token.isEmpty else { return "" }
        return "username=x-access-token\npassword=\(token)\n"
    }

    /// git の `credential.helper` に書く値（パスに空白があっても動くよう、シェルのクォートで囲む）
    public static func helper(executable: URL) -> String {
        "!'\(executable.path.replacingOccurrences(of: "'", with: "'\\''"))' git-credential"
    }
}
