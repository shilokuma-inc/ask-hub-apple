import AskHubEpics
import AskHubProtocol
import Foundation

/// 人がする作業で受け渡すもの（`handover`）の決まり（`docs/renewal/flows.md` の「人がする作業」）。
///
/// `file` で渡したファイルは状態リポジトリ（private）に残り、実装の Claude にも渡すので、秘密を含まないものだけにする。
/// 秘密鍵・パスワード・トークン・API キーを含むものは `secret` にする（GitHub の Secrets に入れる）
enum HandoverRules {
    /// ゴールを作る・直す Claude に伝える決まり
    static let fileRule = """
        handover の file（ファイルを渡す）は、秘密を含まないもの（設定ファイル・証明書の公開の部分など）だけにする。\
        秘密鍵・パスワード・トークン・API キーを含むものは secret にする（渡したファイルは状態リポジトリに残り、実装の Claude にも渡すため）
        """

    /// `file` の作業の名前（`title`）と手順（`steps`）に出たら直させる、秘密らしい言葉。
    /// 小文字にして空白を除いた文と比べる（「API Key」「api キー」などの書き方の違いを同じに扱う）。
    /// 「公開鍵」まで当てないよう、「鍵」だけでは当てない
    static let secretWords = [
        "秘密鍵", "署名鍵", "privatekey", "パスワード", "password", "パスフレーズ", "passphrase", "トークン", "token",
        "apiキー", "apikey", "api_key", "シークレット", "secret", "credential", ".p8", ".p12", ".pfx", ".key"
    ]

    /// `file` の作業の名前と手順に秘密らしい言葉があれば、直させる文を返す
    static func problems(in humanTasks: [GoalDraft.HumanTask]) -> [String] {
        humanTasks.filter { $0.handover.kind == .file }.compactMap { task in
            let text = ([task.title] + task.steps).joined(separator: "\n").lowercased().filter { !$0.isWhitespace }
            let found = secretWords.filter(text.contains)
            guard !found.isEmpty else { return nil }
            return "\(task.id): file で渡す作業の名前か手順に、秘密らしい言葉（\(found.joined(separator: "・"))）がある。"
                + "秘密を含むものなら handover を secret にし、含まないなら秘密と読める言葉を使わずに書き直す"
        }
    }
}
