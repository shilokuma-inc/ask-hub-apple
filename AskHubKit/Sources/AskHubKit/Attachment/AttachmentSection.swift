import Foundation

/// 本文の末尾に置く添付欄（`docs/protocol.md` の「添付ファイル」の「添付欄」）。
///
/// ```markdown
/// （本文）
///
/// ### 添付ファイル
/// - [design.png](https://github.com/<owner>/<repo>/blob/<commit>/files/<uuid>/design.png)（画像・117 KB）
///   <!-- ask-hub:attachment {...} -->
/// ```
///
/// 回答の 1 行目の `回答: ` や、本文の先頭に置くほかの目印を崩さないよう、いつも末尾に足す
public enum AttachmentSection {
    /// 添付欄の見出し
    public static let heading = "### 添付ファイル"

    /// 本文の末尾に添付欄を足す。添付が無ければ本文をそのまま返す
    /// - Parameter repository: 添付を置いたリポジトリ（`owner/repo`）
    public static func appending(_ attachments: [AttachmentMarker], to body: String, repository: String) -> String {
        guard !attachments.isEmpty else {
            return body
        }
        // 目印は 2 文字下げて項目の中に置く（行頭の HTML コメントは箇条書きを途切れさせ、項目ごとに別の箇条書きになるため）
        let lines = attachments.map { attachment in
            "- \(link(for: attachment, repository: repository))（\(attachment.kind.displayName)・"
                + "\(AttachmentSize.displayText(bytes: attachment.size))）\n  \(attachment.marker)"
        }
        let section = ([heading] + lines).joined(separator: "\n")
        let trimmedBody = body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return trimmedBody.isEmpty ? section : "\(trimmedBody)\n\n\(section)"
    }

    /// 添付を開くリンクの URL。ブランチから消した後も開けるよう、コミットの固定リンクにする
    public static func url(for attachment: AttachmentMarker, repository: String) -> URL? {
        var components: [String] = repository.split(separator: "/").map(String.init)
        components += ["blob", attachment.commit]
        // 結合文字などが `/` と 1 つの Character にまとまることがあるので、Unicode スカラーの単位で分ける
        components += attachment.path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
        let path = components
            .map { $0.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: "https://github.com/\(path)")
    }

    /// `[名前](URL)`。名前の Markdown の記号はエスケープする
    private static func link(for attachment: AttachmentMarker, repository: String) -> String {
        let name = escapeMarkdown(displayName(of: attachment))
        guard let url = url(for: attachment, repository: repository) else {
            return name
        }
        return "[\(name)](\(url.absoluteString))"
    }

    /// 表示する名前。元の名前の改行などの制御文字は空白にする（本文の 1 行に収めるため）
    private static func displayName(of attachment: AttachmentMarker) -> String {
        let scalars = attachment.name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let special: Set<Character> = ["\\", "[", "]", "(", ")", "*", "_", "`", "<", ">", "!", "#", "|", "~"]
        return text.reduce(into: "") { result, character in
            if special.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }

    /// パスの 1 要素に残す文字（RFC 3986 の unreserved）。それ以外はパーセントエンコードする
    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
