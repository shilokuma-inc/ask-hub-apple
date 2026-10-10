import Foundation

/// 仮決め一覧の 1 項目を承認する（本文のチェックを付ける）。テストでは差し替える
public protocol DecisionApproving: Sendable {
    /// 仮決め一覧（`decision-log`）の本文を読み直し、チェックの後ろが `text` と全文一致する未確認の行だけにチェックを付ける。
    /// 承認ではコメントを投稿しない
    func approve(_ text: String, in issue: InboxIssue) async throws -> DecisionApproval
}

/// 承認の結果。どれも読み直した（書き換えたときは書き換えた後の）本文を持つ
public enum DecisionApproval: Sendable, Equatable {
    /// チェックを付けた
    case approved(body: String)
    /// 同じ行がすでに確認済みだった（書き換えていない）
    case alreadyApproved(body: String)
    /// 該当の行が無かった（ループが書き換えた・消えた）。書き換えていないので、本文を表示し直す
    case notFound(body: String)
}

/// 承認できないときのエラー
public enum DecisionApprovalError: Error, Equatable, Sendable {
    /// 仮決め一覧以外の Issue は書き換えない
    case notDecisionLog
}

/// 仮決め一覧の本文のチェックの書き換え（副作用なし）。取り決めは `docs/protocol.md` の「アプリからの承認（本文のチェック）」
public enum DecisionLogCheck {
    /// `body` のうち、チェックの後ろが `text` と全文一致する行の扱い
    public enum Result: Sendable, Equatable {
        /// 最初に一致した未確認の行のチェックだけを付けた本文
        case checked(String)
        /// 未確認の行は無く、確認済みの行が一致した
        case alreadyChecked
        /// 一致する行が無い
        case notFound
    }

    private static let unchecked = "- [ ]"
    private static let checked = "- [x]"
    private static let checkedPrefixes = [checked, "- [X]"]

    /// 一致の判定では行頭・行末の空白を比べない。ほかの行・改行コード・行の残りはそのまま残す
    public static func check(_ text: String, in body: String) -> Result {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `\r\n` を 1 文字として扱わないよう、Foundation の `\n` 区切りで分けて改行コードを残す
        var lines = body.components(separatedBy: "\n")
        var foundChecked = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(unchecked), rest(of: trimmed, after: unchecked) == target,
               let range = line.range(of: unchecked) {
                lines[index] = line.replacingCharacters(in: range, with: checked)
                return .checked(lines.joined(separator: "\n"))
            }
            if let prefix = checkedPrefixes.first(where: { trimmed.hasPrefix($0) }), rest(of: trimmed, after: prefix) == target {
                foundChecked = true
            }
        }
        return foundChecked ? .alreadyChecked : .notFound
    }

    private static func rest(of line: String, after prefix: String) -> String {
        line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}

/// GitHub の REST API で仮決め一覧の本文のチェックを付ける（Discussion #349 の Q2）。トークンには Issues の書き込み権限が要る。
/// GitHub に条件付きの書き込みが無いため、読み直しから書き戻しまでの間にループが本文を書き換えると上書きしうる（受け入れ済み）
public struct GitHubDecisionApprover: DecisionApproving {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func approve(_ text: String, in issue: InboxIssue) async throws -> DecisionApproval {
        guard issue.kind == .decisionLog else {
            throw DecisionApprovalError.notDecisionLog
        }
        let path = "repos/\(issue.repository)/issues/\(issue.number)"
        // 人やループの書き換えを古い本文で上書きしないよう、書き換えの直前に読み直す
        let current = try await client.get(path, as: IssueBody.self).body ?? ""
        switch DecisionLogCheck.check(text, in: current) {
        case let .checked(body):
            let updated = try await client.send("PATCH", path, body: BodyUpdate(body: body), as: IssueBody.self)
            return .approved(body: updated.body ?? body)
        case .alreadyChecked:
            return .alreadyApproved(body: current)
        case .notFound:
            return .notFound(body: current)
        }
    }
}

private struct IssueBody: Decodable {
    let body: String?
}

private struct BodyUpdate: Encodable, Sendable {
    let body: String
}
