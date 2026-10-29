import AskHubKit
import Foundation

/// zip を展開した結果（`docs/protocol.md` の「zip の展開」）。一覧は中央ディレクトリの順
public struct AttachmentZipContents: Sendable, Equatable {
    /// `claude` に読ませる種類のファイル
    public struct ReadableFile: Sendable, Equatable {
        /// 展開先の絶対パス
        public let path: String
        /// zip の中のパス（`.` と空の要素を詰めたもの）
        public let entryPath: String
        /// 拡張子から決めた MIME タイプ
        public let type: String
        public let size: Int

        /// テキスト・画像（SVG を含む）・PDF のどれか
        public var kind: AttachmentKind {
            AttachmentKind(mimeType: type)
        }
    }

    /// 読めない種類のファイル（取り込みの素材として使える）
    public struct Material: Sendable, Equatable {
        /// 展開先の絶対パス
        public let path: String
        /// zip の中のパス
        public let entryPath: String
        public let size: Int
    }

    /// 展開しなかった項目
    public struct SkippedEntry: Sendable, Equatable {
        /// zip の中の名前。UTF-8 として読めないバイトと制御文字は U+FFFD にしてある
        public let entryPath: String
        public let reason: AttachmentZipSkipReason
    }

    /// 展開先のディレクトリの絶対パス（末尾の `/` なし）
    public let directory: String
    public let readableFiles: [ReadableFile]
    public let materials: [Material]
    public let skippedEntries: [SkippedEntry]
}

/// 項目を展開しなかった理由
public enum AttachmentZipSkipReason: Sendable, Equatable {
    /// 名前が UTF-8 として読めない（仮決め）
    case unreadableName
    /// 名前に制御文字がある
    case controlCharacter
    /// 絶対パス（先頭が `/`）
    case absolutePath
    /// `\` やドライブ名（`C:`）がある
    case backslashOrDrive
    /// `..` の要素がある
    case parentDirectory
    /// `.` と空の要素を除くと名前が残らない
    case emptyName
    /// シンボリックリンク（UNIX のモードが `0120000`）
    case symbolicLink
    /// FIFO・デバイスなど、ファイルとディレクトリ以外
    case specialFile
    /// 暗号化されている
    case encrypted
    /// 無圧縮・Deflate 以外の圧縮方式
    case unsupportedCompression(method: UInt16)
    /// `__MACOSX/`・`.DS_Store`・`._*`（仮決め。使う側は一覧に出さなくてよい）
    case macOSMetadata
    /// 既に同じパスがある・ファイルとディレクトリが取り合う・名前が長すぎて書けない
    case conflict

    /// 一覧に出す説明
    public var message: String {
        switch self {
        case .unreadableName:
            "名前が UTF-8 として読めないため展開しませんでした"

        case .controlCharacter:
            "名前に制御文字があるため展開しませんでした"

        case .absolutePath:
            "絶対パスのため展開しませんでした"

        case .backslashOrDrive:
            "名前に \\ やドライブ名があるため展開しませんでした"

        case .parentDirectory:
            "名前に .. があるため展開しませんでした"

        case .emptyName:
            "名前が空のため展開しませんでした"

        case .symbolicLink:
            "シンボリックリンクのため展開しませんでした"

        case .specialFile:
            "ファイルでもディレクトリでもないため展開しませんでした"

        case .encrypted:
            "暗号化されているため展開しませんでした"

        case let .unsupportedCompression(method):
            "対応していない圧縮方式（\(method)）のため展開しませんでした"

        case .macOSMetadata:
            "macOS のメタデータのため展開しませんでした"

        case .conflict:
            "同じパスのファイルが既にある（または名前が長すぎる）ため展開しませんでした"
        }
    }
}

/// zip 全体を展開できなかった理由。展開先は消してある
public enum AttachmentZipError: Error, Sendable, Equatable {
    /// zip を読めなかった
    case unreadable(reason: String)
    /// zip でない（中央ディレクトリの終わりが無い）
    case notZip
    /// 壊れている（位置・目印・CRC-32・大きさが合わない、Deflate を解けない、分割 zip）
    case corrupted(reason: String)
    /// 中央ディレクトリの宣言値の合計が上限を超える
    case declaredTooLarge(bytes: Int, limit: Int)
    /// 展開するファイルの数が上限を超える
    case tooManyFiles(count: Int, limit: Int)
    /// 実際に展開した大きさが上限を超えた
    case extractedTooLarge(limit: Int)
    /// 展開した後の確かめで、シンボリックリンク・特殊なファイル・展開先の外のものが見つかった（`path` は展開先からの相対パス）
    case unsafeExtraction(path: String)
    /// 展開先が zip を含む（展開の前に消すと zip も消えてしまう）
    case destinationContainsArchive
    /// 展開先に書けなかった
    case cannotWrite(reason: String)

    /// ログや一覧に出す説明
    public var message: String {
        switch self {
        case let .unreadable(reason):
            "zip を読めませんでした（\(reason)）"

        case .notZip:
            "zip の形式として読めませんでした"

        case let .corrupted(reason):
            "zip が壊れています（\(reason)）"

        case let .declaredTooLarge(bytes, limit):
            "展開後の大きさ（\(AttachmentSize.displayText(bytes: bytes))）が上限（\(AttachmentSize.displayText(bytes: limit))）を超えるため展開しませんでした"

        case let .tooManyFiles(count, limit):
            "ファイルの数（\(count)）が上限（\(limit)）を超えるため展開しませんでした"

        case let .extractedTooLarge(limit):
            "展開した大きさが上限（\(AttachmentSize.displayText(bytes: limit))）を超えたため使いません"

        case let .unsafeExtraction(path):
            "展開したものにファイルとディレクトリ以外のもの（シンボリックリンクなど）があったため使いません（\(path)）"

        case .destinationContainsArchive:
            "展開先が zip を含むため展開しませんでした"

        case let .cannotWrite(reason):
            "展開先に書けませんでした（\(reason)）"
        }
    }
}
