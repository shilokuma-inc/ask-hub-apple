import Foundation

/// zip の中央ディレクトリを読んだもの（`docs/protocol.md` の「zip の展開」）。
///
/// `zipinfo` はロケールが C（launchd の既定）だと UTF-8 の名前を `??` と出し、`unzip` は名前をワイルドカードやオプションとして読むので、
/// 名前の生のバイト列と宣言値を確かめるために自前で読む
struct AttachmentZipArchive {
    /// 中央ディレクトリの 1 項目
    struct Entry: Equatable {
        /// 名前の生のバイト列（汎用フラグの bit 11 にかかわらず、UTF-8 として読めるかは使う側で確かめる）
        let nameBytes: [UInt8]
        /// version made by の上位バイト（作成元のシステム。3 は UNIX）
        let hostSystem: UInt8
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let externalAttributes: UInt32
        let localHeaderOffset: Int

        /// 汎用フラグの bit 0
        var isEncrypted: Bool {
            flags & 0x0001 != 0
        }

        /// UNIX のファイルの種類（`& 0170000`）。作成元が UNIX（3）か OS X（19）でなければ `nil`
        var unixFileType: UInt32? {
            hostSystem == 3 || hostSystem == 19 ? (externalAttributes >> 16) & 0o170000 : nil
        }
    }

    let entries: [Entry]
    private let bytes: ZipBytes

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralEntrySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    /// 中央ディレクトリの終わりの固定部分と、コメントの最大の長さ
    private static let endOfCentralDirectorySize = 22
    private static let maxCommentLength = 0xFFFF

    init(data: Data) throws(AttachmentZipError) {
        let bytes = ZipBytes(data: data)
        self.bytes = bytes
        let end = try Self.locateCentralDirectory(in: bytes)
        entries = try Self.readEntries(in: bytes, at: end.offset, size: end.size, count: end.count)
    }

    /// 項目の圧縮された中身（ローカルファイルヘッダの後ろ）
    func compressedData(of entry: Entry) throws(AttachmentZipError) -> Data {
        let offset = entry.localHeaderOffset
        guard bytes.uint32(at: offset) == Self.localHeaderSignature,
              let nameLength = bytes.uint16(at: offset + 26),
              let extraLength = bytes.uint16(at: offset + 28),
              let data = bytes.slice(at: offset + 30 + Int(nameLength) + Int(extraLength), count: entry.compressedSize) else {
            throw .corrupted(reason: "ローカルファイルヘッダが読めません")
        }
        return data
    }

    // MARK: - 中央ディレクトリの位置

    private struct CentralDirectory {
        let offset: Int
        let size: Int
        let count: Int
    }

    private static func locateCentralDirectory(in bytes: ZipBytes) throws(AttachmentZipError) -> CentralDirectory {
        // 末尾から、コメントの最大の長さまでさかのぼって探す
        let last = bytes.count - endOfCentralDirectorySize
        let first = max(0, last - maxCommentLength)
        let candidates = stride(from: last, through: first, by: -1)
        guard last >= 0, let end = candidates.first(where: { bytes.uint32(at: $0) == endOfCentralDirectorySignature }) else {
            throw .notZip
        }
        guard let disk = bytes.uint16(at: end + 4),
              let centralDisk = bytes.uint16(at: end + 6),
              let diskCount = bytes.uint16(at: end + 8),
              let count = bytes.uint16(at: end + 10),
              let size = bytes.uint32(at: end + 12),
              let offset = bytes.uint32(at: end + 16) else {
            throw .notZip
        }
        let directory: CentralDirectory
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            directory = try zip64CentralDirectory(in: bytes, endOffset: end)
        } else {
            guard disk == 0, centralDisk == 0, diskCount == count else {
                throw .corrupted(reason: "分割された zip には対応していません")
            }
            directory = CentralDirectory(offset: Int(offset), size: Int(size), count: Int(count))
        }
        // 1 項目は少なくとも 46 バイトある。数を偽って大きな配列を作らせない
        // ZIP64 の値は大きくできるので、足し算であふれないよう引き算で比べる
        guard directory.offset <= end, directory.size <= end - directory.offset, directory.count <= directory.size / 46 else {
            throw .corrupted(reason: "中央ディレクトリの位置が合いません")
        }
        return directory
    }

    private static func zip64CentralDirectory(in bytes: ZipBytes, endOffset: Int) throws(AttachmentZipError) -> CentralDirectory {
        let locator = endOffset - 20
        guard bytes.uint32(at: locator) == zip64LocatorSignature,
              let recordOffset = bytes.int(at: locator + 8),
              bytes.uint32(at: recordOffset) == zip64EndSignature,
              let disk = bytes.uint32(at: recordOffset + 16),
              let centralDisk = bytes.uint32(at: recordOffset + 20),
              let diskCount = bytes.int(at: recordOffset + 24),
              let count = bytes.int(at: recordOffset + 32),
              let size = bytes.int(at: recordOffset + 40),
              let offset = bytes.int(at: recordOffset + 48) else {
            throw .corrupted(reason: "ZIP64 の中央ディレクトリの終わりが読めません")
        }
        guard disk == 0, centralDisk == 0, diskCount == count else {
            throw .corrupted(reason: "分割された zip には対応していません")
        }
        return CentralDirectory(offset: offset, size: size, count: count)
    }

    // MARK: - 中央ディレクトリの項目

    private static func readEntries(in bytes: ZipBytes, at start: Int, size: Int, count: Int) throws(AttachmentZipError) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var offset = start
        let limit = start + size
        for _ in 0..<count {
            guard bytes.uint32(at: offset) == centralEntrySignature,
                  let versionMadeBy = bytes.uint16(at: offset + 4),
                  let flags = bytes.uint16(at: offset + 8),
                  let method = bytes.uint16(at: offset + 10),
                  let crc32 = bytes.uint32(at: offset + 16),
                  let compressedSize = bytes.uint32(at: offset + 20),
                  let uncompressedSize = bytes.uint32(at: offset + 24),
                  let nameLength = bytes.uint16(at: offset + 28).map(Int.init),
                  let extraLength = bytes.uint16(at: offset + 30).map(Int.init),
                  let commentLength = bytes.uint16(at: offset + 32).map(Int.init),
                  let externalAttributes = bytes.uint32(at: offset + 38),
                  let localHeaderOffset = bytes.uint32(at: offset + 42),
                  let name = bytes.slice(at: offset + 46, count: nameLength),
                  let extra = bytes.slice(at: offset + 46 + nameLength, count: extraLength) else {
                throw .corrupted(reason: "中央ディレクトリの項目が読めません")
            }
            let sizes = try zip64Values(
                in: ZipBytes(data: extra),
                uncompressed: uncompressedSize,
                compressed: compressedSize,
                offset: localHeaderOffset
            )
            entries.append(Entry(
                nameBytes: [UInt8](name),
                hostSystem: UInt8(versionMadeBy >> 8),
                flags: flags,
                method: method,
                crc32: crc32,
                compressedSize: sizes.compressed,
                uncompressedSize: sizes.uncompressed,
                externalAttributes: externalAttributes,
                localHeaderOffset: sizes.offset
            ))
            offset += 46 + nameLength + extraLength + commentLength
            guard offset <= limit else {
                throw .corrupted(reason: "中央ディレクトリの項目が範囲を超えています")
            }
        }
        return entries
    }

    /// 項目の展開後・圧縮後の大きさと、ローカルファイルヘッダの位置
    private struct Sizes {
        let uncompressed: Int
        let compressed: Int
        let offset: Int
    }

    /// 32 ビットの値が `0xFFFFFFFF` のものは、ZIP64 の拡張フィールド（`0x0001`）に展開後・圧縮後・オフセットの順で 64 ビットの値がある
    private static func zip64Values(
        in extra: ZipBytes,
        uncompressed: UInt32,
        compressed: UInt32,
        offset: UInt32
    ) throws(AttachmentZipError) -> Sizes {
        let sentinel: UInt32 = 0xFFFF_FFFF
        guard uncompressed == sentinel || compressed == sentinel || offset == sentinel else {
            return Sizes(uncompressed: Int(uncompressed), compressed: Int(compressed), offset: Int(offset))
        }
        var position = 0
        while let id = extra.uint16(at: position), let length = extra.uint16(at: position + 2) {
            if id == 0x0001 {
                var field = position + 4
                func next(_ value: UInt32) -> Int? {
                    guard value == sentinel else {
                        return Int(value)
                    }
                    defer { field += 8 }
                    return field + 8 <= position + 4 + Int(length) ? extra.int(at: field) : nil
                }
                guard let uncompressed = next(uncompressed), let compressed = next(compressed), let offset = next(offset) else {
                    break
                }
                return Sizes(uncompressed: uncompressed, compressed: compressed, offset: offset)
            }
            position += 4 + Int(length)
        }
        throw .corrupted(reason: "ZIP64 の拡張フィールドが読めません")
    }
}

/// リトルエンディアンの値を範囲を確かめて読む（`Data` のスライスでも 0 から数える）
struct ZipBytes {
    let data: Data

    var count: Int {
        data.count
    }

    func uint16(at offset: Int) -> UInt16? {
        value(at: offset, size: 2).map(UInt16.init)
    }

    func uint32(at offset: Int) -> UInt32? {
        value(at: offset, size: 4).map(UInt32.init)
    }

    /// 64 ビットの値を `Int` として読む。`Int.max` を超えれば読めない
    func int(at offset: Int) -> Int? {
        value(at: offset, size: 8).flatMap { Int(exactly: $0) }
    }

    func slice(at offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            return nil
        }
        let start = data.startIndex + offset
        return data[start..<(start + length)]
    }

    private func value(at offset: Int, size: Int) -> UInt64? {
        guard let bytes = slice(at: offset, count: size) else {
            return nil
        }
        return bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
