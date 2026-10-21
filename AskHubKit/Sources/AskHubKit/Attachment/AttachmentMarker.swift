import Foundation

/// 添付ファイル 1 つを指す目印。本文の末尾の添付欄（`AttachmentSection`）に置く。
///
/// ```html
/// <!-- ask-hub:attachment {"commit":"…","name":"design.png","path":"files/<uuid>/design.png","sha":"…","size":120000,"type":"image/png"} -->
/// ```
///
/// 詳細は `docs/protocol.md` の「添付ファイル」を参照。
/// ファイルは依頼先リポジトリの `askhub/attachments` ブランチの `path` にあり、読むときは `sha`（blob SHA）で取る。
/// **信用する author が書いた本文の目印だけを読む**（ここでは判定しない。`TrustedAuthors` を使う）。
public struct AttachmentMarker: Sendable, Equatable, Hashable, Codable {
    /// `askhub/attachments` ブランチの中のパス（`files/<UUID（小文字）>/<ファイル名>`）
    public var path: String
    /// ファイルの blob SHA（40 桁の 16 進）
    public var sha: String
    /// ファイルを上げたコミットの SHA（40 桁の 16 進）。添付欄のリンクに使う
    public var commit: String
    /// 元のファイル名
    public var name: String
    /// バイト数
    public var size: Int
    /// MIME タイプ（例: `image/png`）
    public var type: String

    public init(path: String, sha: String, commit: String, name: String, size: Int, type: String) {
        self.path = path
        self.sha = sha
        self.commit = commit
        self.name = name
        self.size = size
        self.type = type
    }

    /// 添付を置くブランチ
    public static let branch = "askhub/attachments"

    /// 添付 1 つ分のパス（`files/<UUID（小文字）>/<安全にしたファイル名>`）
    public static func path(id: UUID, fileName: String) -> String {
        "\(pathPrefix)\(id.uuidString.lowercased())/\(AttachmentFileName.sanitized(fileName))"
    }

    /// 添付の種類（`type` から決める）
    public var kind: AttachmentKind {
        AttachmentKind(mimeType: type)
    }

    /// 目印として読んでよい形か。
    /// `path` が `files/<UUID（小文字）>/<ファイル名>` の形で、`sha`・`commit` が 40 桁の 16 進、`size` が 0 以上、`name`・`type` が空でないこと
    public var isWellFormed: Bool {
        Self.isWellFormedPath(path)
            && Self.isObjectID(sha)
            && Self.isObjectID(commit)
            && size >= 0
            && !name.isEmpty
            && !type.isEmpty
    }

    // MARK: - 目印の生成・パース

    private static let pathPrefix = "files/"
    private static let keyword = "ask-hub:attachment"

    /// 添付欄に置く HTML コメント。
    ///
    /// 文字列の中の `>` は `\u003e`、`<` は `\u003c` にする（目印の終わりの `-->` と取り違えないため。`VerifyMarker` と同じ）。
    /// `<` も置き換えるのは、名前の `<!--` を、読む側が本文の閉じていないコメントと見分けられるようにするため（`parseAll`）
    public var marker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        let json = encoded
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "<", with: "\\u003c")
        return "\(MarkerComment.open) \(Self.keyword) \(json) \(MarkerComment.close)"
    }

    /// 本文の中の添付の目印を、現れた順にすべて読む。
    ///
    /// 目印は本文のどこにあってもよい（添付欄は本文の末尾にあり、先頭にはほかの目印が来るため）。
    /// 形の誤った目印（`isWellFormed` でないもの・JSON として読めないもの）は無視する。
    /// 同じ `path` の目印が重なっていれば、最初のものだけを返す
    public static func parseAll(_ body: String) -> [Self] {
        var markers: [Self] = []
        var seenPaths: Set<String> = []
        var rest = body[...]
        while let openRange = rest.range(of: MarkerComment.open) {
            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: MarkerComment.close) else {
                break
            }
            // 本文に閉じていない `<!--`（コードの例など）があると、次の目印の `-->` と組になる。
            // 中にさらに `<!--` があれば、最後のものからを 1 つのコメントとみなす（目印を読み落とさないため）
            var inner = afterOpen[..<closeRange.lowerBound]
            if let lastOpen = inner.range(of: MarkerComment.open, options: .backwards) {
                inner = inner[lastOpen.upperBound...]
            }
            if let marker = parse(inner: inner),
               seenPaths.insert(marker.path).inserted {
                markers.append(marker)
            }
            rest = afterOpen[closeRange.upperBound...]
        }
        return markers
    }

    /// HTML コメントの中身（`<!--` と `-->` の間）を目印として読む
    private static func parse(inner: Substring) -> Self? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(keyword) else {
            return nil
        }
        let rest = trimmed.dropFirst(keyword.count)
        // `ask-hub:attachments-cleaned` のような別の語を誤って拾わないよう、直後は空白に限る
        guard rest.first?.isWhitespace == true,
              let marker = try? JSONDecoder().decode(Self.self, from: Data(rest.utf8)),
              marker.isWellFormed else {
            return nil
        }
        return marker
    }

    private static func isWellFormedPath(_ path: String) -> Bool {
        // 結合文字などが `/` と 1 つの Character にまとまることがあるので、Unicode スカラーの単位で分ける
        let parts = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard parts.count == 3, parts[0] == "files",
              let id = UUID(uuidString: String(parts[1])),
              id.uuidString.lowercased() == parts[1] else {
            return false
        }
        let fileName = String(parts[2])
        return !fileName.isEmpty && AttachmentFileName.sanitized(fileName) == fileName
    }

    /// `Character.isHexDigit` は全角の数字・英字も認めるので、ASCII の小文字の 16 進だけを数える
    private static let hexDigits = Set("0123456789abcdef")

    private static func isObjectID(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(hexDigits.contains)
    }
}
