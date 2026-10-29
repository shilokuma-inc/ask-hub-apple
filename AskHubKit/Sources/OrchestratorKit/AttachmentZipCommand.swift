import Foundation

/// `askhub-orchestrator extract-zip <zip> <展開先>` の本体（Discussion #761 の Q2・Issue #771）。
///
/// ループの準備（`start-loop.sh`）が zip の添付を `AttachmentZipExtractor` で展開できるよう、結果をタブ区切りの行で返す。
/// 規則をシェルで作り直さず、Swift の実装を 1 つだけにするため。設定ファイルも GitHub のトークンも使わない。
///
/// 出力（標準出力。1 行に 1 つ、値はタブ区切り）:
/// - 1 行目: `extracted\t<展開先>\t<読めるファイルの数>\t<素材の数>\t<展開しなかった項目の数>`
/// - `readable\t<MIME タイプ>\t<バイト数>\t<zip の中のパス>\t<展開先の絶対パス>`
/// - `material\t<バイト数>\t<zip の中のパス>\t<展開先の絶対パス>`
/// - `skipped\t<理由>\t<zip の中の名前>`（macOS のメタデータは出さない）
/// - 展開できなければ `failed\t<理由>` の 1 行だけで、終了コードは `failureStatus`
///
/// 値のタブ・改行・制御文字は空白にする（1 行 = 1 項目を崩さない）
public enum AttachmentZipCommand {
    /// 展開できなかったときの終了コード（`EX_DATAERR`）
    public static let failureStatus: Int32 = 65

    public struct Result: Sendable, Equatable {
        public let output: String
        public let status: Int32
    }

    /// `zipPath` を `destinationPath` に展開して、出力と終了コードを返す。相対パスは今のディレクトリから解く
    public static func run(
        zipPath: String,
        destinationPath: String,
        extractor: AttachmentZipExtractor = AttachmentZipExtractor()
    ) -> Result {
        let archive = URL(fileURLWithPath: zipPath, isDirectory: false)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        do {
            let contents = try extractor.extract(zipAt: archive, to: destination)
            return Result(output: output(for: contents), status: 0)
        } catch {
            return Result(output: failureOutput(for: error), status: failureStatus)
        }
    }

    /// 展開できたときの出力（末尾に改行）
    public static func output(for contents: AttachmentZipContents) -> String {
        let skipped = contents.skippedEntries.filter { $0.reason != .macOSMetadata }
        var lines = [
            line("extracted", contents.directory, "\(contents.readableFiles.count)", "\(contents.materials.count)", "\(skipped.count)")
        ]
        lines += contents.readableFiles.map { line("readable", $0.type, "\($0.size)", $0.entryPath, $0.path) }
        lines += contents.materials.map { line("material", "\($0.size)", $0.entryPath, $0.path) }
        lines += skipped.map { line("skipped", $0.reason.message, $0.entryPath) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 展開できなかったときの出力（末尾に改行）
    public static func failureOutput(for error: AttachmentZipError) -> String {
        line("failed", error.message) + "\n"
    }

    private static func line(_ values: String...) -> String {
        values.map(sanitized).joined(separator: "\t")
    }

    /// タブ・改行・制御文字（U+0000〜U+001F・U+007F〜U+009F）と行・段落の区切り（U+2028・U+2029）を空白にする
    static func sanitized(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            let code = scalar.value
            let isBreaking = code < 0x20 || (0x7F...0x9F).contains(code) || code == 0x2028 || code == 0x2029
            return isBreaking ? " " : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
