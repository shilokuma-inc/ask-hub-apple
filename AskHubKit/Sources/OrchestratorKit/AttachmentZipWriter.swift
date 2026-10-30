import Compression
import Foundation
import zlib

/// 展開すると決めた項目だけを展開先に書く。書くのはこの型で作るファイルとディレクトリだけで、シンボリックリンクは作らない。
/// ファイルは `O_CREAT | O_EXCL | O_NOFOLLOW` で新しく作る（既にあるパスやリンクの先には書かない）
struct AttachmentZipWriter {
    /// 展開先の絶対パス（末尾の `/` なし）
    let root: String
    /// 実際に書いた大きさの合計の上限
    let limit: Int
    /// これまでに書いた大きさの合計
    private(set) var written = 0

    init(root: String, limit: Int) {
        self.root = root
        self.limit = limit
    }

    /// ディレクトリを作る。ファイルと取り合う・名前が長すぎるときは `false`
    func makeDirectory(_ components: [String]) throws(AttachmentZipError) -> Bool {
        try makeDirectories(components[...])
    }

    /// ファイルを書いて絶対パスを返す。既に同じパスがある・名前が長すぎるときは `nil`。
    /// 実際の大きさの合計が上限を超えたら `.extractedTooLarge`、大きさや CRC-32 が宣言値と合わなければ `.corrupted` を投げる
    mutating func writeFile(
        _ components: [String],
        entry: AttachmentZipArchive.Entry,
        from archive: AttachmentZipArchive
    ) throws(AttachmentZipError) -> String? {
        guard try makeDirectories(components.dropLast()) else {
            return nil
        }
        let path = ([root] + components).joined(separator: "/")
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            if Self.conflictErrors.contains(code) {
                return nil
            }
            throw .cannotWrite(reason: Self.describe(code))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let compressed = try archive.compressedData(of: entry)
        let limit = limit
        let alreadyWritten = written
        var size = 0
        var checksum = crc32(0, nil, 0)
        // 書く前に合計を確かめる（宣言値を偽った zip 爆弾でも、上限を超えて書かない）
        func sink(_ buffer: UnsafeRawBufferPointer) throws {
            size += buffer.count
            guard size <= limit - alreadyWritten else {
                throw AttachmentZipError.extractedTooLarge(limit: limit)
            }
            checksum = crc32(checksum, buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(buffer.count))
            try handle.write(contentsOf: Data(buffer))
        }
        do {
            if entry.method == 0 {
                guard compressed.count == entry.uncompressedSize else {
                    throw AttachmentZipError.corrupted(reason: "無圧縮の項目の大きさが宣言と合いません")
                }
                try compressed.withUnsafeBytes(sink)
            } else {
                try AttachmentZipInflater.inflate(compressed, into: sink)
            }
            try handle.close()
        } catch let error as AttachmentZipError {
            throw error
        } catch {
            throw .cannotWrite(reason: error.localizedDescription)
        }
        guard size == entry.uncompressedSize else {
            throw .corrupted(reason: "展開した大きさが宣言と合いません")
        }
        guard UInt32(truncatingIfNeeded: checksum) == entry.crc32 else {
            throw .corrupted(reason: "CRC-32 が合いません")
        }
        written += size
        return path
    }

    /// 既にあるパス・ディレクトリとファイルの取り合い・長すぎる名前。その項目だけを飛ばす
    private static let conflictErrors: Set<Int32> = [EEXIST, EISDIR, ENOTDIR, ELOOP, ENAMETOOLONG]

    /// 展開先の下に要素を 1 つずつ作る。既にあるディレクトリはそのまま使う（展開先の下にリンクは無いので、たどる先も展開先の下）
    private func makeDirectories(_ components: ArraySlice<String>) throws(AttachmentZipError) -> Bool {
        var path = root
        for component in components {
            path += "/" + component
            guard mkdir(path, 0o755) != 0 else {
                continue
            }
            let code = errno
            if code == EEXIST, Self.isDirectory(path) {
                continue
            }
            if Self.conflictErrors.contains(code) {
                return false
            }
            throw .cannotWrite(reason: Self.describe(code))
        }
        return true
    }

    /// リンクをたどらずにディレクトリかを見る
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Deflate（zip の圧縮方式 8）を解く。Compression の `COMPRESSION_ZLIB` はヘッダの無い raw Deflate（RFC 1951）で、zip の中身と同じ形
enum AttachmentZipInflater {
    private static let chunkSize = 64 * 1_024

    /// 解いた分を `sink` に少しずつ渡す（全体をメモリに展開しない）。`sink` が投げたら止める
    static func inflate(_ input: Data, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AttachmentZipError.corrupted(reason: "Deflate を解く準備ができません")
        }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.baseAddress else {
                throw AttachmentZipError.corrupted(reason: "Deflate の中身が空です")
            }
            stream.pointee.src_ptr = source.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunkSize
                let remaining = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    try sink(UnsafeRawBufferPointer(start: buffer, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return

                case COMPRESSION_STATUS_OK:
                    // 入力を使い切っても終わりが来ない（途中で切れている）なら止める
                    if produced == 0, stream.pointee.src_size == remaining {
                        throw AttachmentZipError.corrupted(reason: "Deflate の中身が途中で終わっています")
                    }

                default:
                    throw AttachmentZipError.corrupted(reason: "Deflate を解けません")
                }
            }
        }
    }
}
