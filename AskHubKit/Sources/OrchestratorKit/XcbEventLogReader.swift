import Foundation

/// xcb のイベントログ（`events.jsonl`）を、前回読んだ位置の続きから読む。
///
/// xcb は 1 行書くたびに大きさを確かめ、5MB を超えたら `events.jsonl` を `events.jsonl.1` に移す（次の行から新しい `events.jsonl` に書く）。
/// 読んだファイルを inode で覚え、それが `.1` に移っていたら残りを `.1` から読んでから新しいファイルを頭から読む。
/// 書きかけの最後の行（改行で終わっていない行）は読まずに残し、次に読む。読めない行は読み飛ばす。
///
/// 最初の読み取り（位置を覚えていないとき）は、`.1` と `events.jsonl` を頭から読む（オーケストレーターを再起動しても、
/// 残っているログから直近のビルドと移動を組み立て直せるように）。位置はファイルに保存しない
public struct XcbEventLogReader: Sendable {
    /// イベントログのファイル名
    public static let fileName = "events.jsonl"
    /// 回したイベントログのファイル名
    public static let rotatedFileName = "events.jsonl.1"

    /// 読んだ位置（どのファイルの何バイト目まで読んだか）
    public struct Position: Sendable, Equatable {
        /// ファイルの inode
        public var fileNumber: UInt64
        /// 読み終えたバイト数（改行で終わる行の終わり）
        public var offset: UInt64
    }

    /// `events.jsonl` を置くディレクトリ
    public let directory: URL
    /// 前回読んだ位置。まだ読んでいなければ `nil`
    public private(set) var position: Position?

    public init(directory: URL) {
        self.directory = directory
    }

    private var currentURL: URL {
        directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    private var rotatedURL: URL {
        directory.appending(path: Self.rotatedFileName, directoryHint: .notDirectory)
    }

    /// 前回の続きから、増えたイベントを古い順に読む。ファイルが無ければ空
    public mutating func readNewEvents() -> [XcbEvent] {
        let current = Self.fileNumber(of: currentURL)
        let rotated = Self.fileNumber(of: rotatedURL)
        var events: [XcbEvent] = []

        // 前回読んだファイルがまだ `events.jsonl` なら、その続きだけを読む
        if let position, position.fileNumber == current {
            let start = Self.fileSize(of: currentURL) < position.offset ? 0 : position.offset
            events += read(currentURL, fileNumber: position.fileNumber, from: start, keepsPartialLine: true)
            return events
        }

        // 前回読んだファイルが `.1` に移った・まだ読んでいない・前回のファイルがもう無い（続けて 2 回回った）
        if let rotated {
            let start = position?.fileNumber == rotated ? position?.offset ?? 0 : 0
            // 回したファイルにはもう書かれないので、改行で終わっていない最後の行も読む
            events += read(rotatedURL, fileNumber: rotated, from: start, keepsPartialLine: false)
        }
        if let current {
            events += read(currentURL, fileNumber: current, from: 0, keepsPartialLine: true)
        }
        return events
    }

    /// `start` バイト目から読み、読み終えた位置を覚える
    private mutating func read(_ url: URL, fileNumber: UInt64, from start: UInt64, keepsPartialLine: Bool) -> [XcbEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else {
            position = Position(fileNumber: fileNumber, offset: start)
            return []
        }
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        if keepsPartialLine {
            // 最後の改行より後ろは書きかけなので、次に読む
            end = data.lastIndex(of: newline).map { data.index(after: $0) } ?? data.startIndex
        }
        position = Position(fileNumber: fileNumber, offset: start + UInt64(end - data.startIndex))
        return data[data.startIndex..<end]
            .split(separator: newline)
            .compactMap { String(bytes: $0, encoding: .utf8).flatMap(XcbEvent.init(line:)) }
    }

    private static func fileNumber(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private static func fileSize(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
