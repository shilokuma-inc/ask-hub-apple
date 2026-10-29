import Foundation
import zlib

/// テスト用の zip の 1 項目。名前・モード・フラグ・宣言値を自由に決めて、悪い zip を組み立てる
struct TestZipEntry {
    var name: [UInt8]
    var content: Data
    /// 0（無圧縮）か 8（Deflate）。ほかの値は中身を無圧縮のまま書く
    var method: UInt16 = 0
    var flags: UInt16 = 0
    var hostSystem: UInt8 = 3
    var unixMode: UInt32 = 0o100644
    /// 中央ディレクトリの展開後の大きさ（宣言値）を偽るとき
    var declaredSize: Int?
    /// 中央ディレクトリの CRC-32 を偽るとき
    var declaredCRC: UInt32?
    /// 大きさとオフセットを ZIP64 の拡張フィールドに書く
    var zip64 = false

    init(_ name: String, _ content: String = "", method: UInt16 = 0, unixMode: UInt32 = 0o100644) {
        self.init(bytes: Array(name.utf8), Data(content.utf8), method: method, unixMode: unixMode)
    }

    init(bytes name: [UInt8], _ content: Data, method: UInt16 = 0, unixMode: UInt32 = 0o100644) {
        self.name = name
        self.content = content
        self.method = method
        self.unixMode = unixMode
    }

    static func directory(_ name: String) -> Self {
        Self(name, unixMode: 0o040755)
    }
}

enum TestZip {
    /// 項目を順に並べた zip のバイト列（ローカルファイルヘッダ・中身・中央ディレクトリ・中央ディレクトリの終わり）
    static func build(_ entries: [TestZipEntry]) throws -> Data {
        var body = Data()
        var central = Data()
        for entry in entries {
            let stored = try storedBytes(of: entry)
            let crc = UInt32(truncatingIfNeeded: entry.content.withUnsafeBytes { raw in
                crc32(0, raw.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(raw.count))
            })
            let offset = body.count
            let uncompressed = entry.declaredSize ?? entry.content.count
            let size32: (UInt32, UInt32) = entry.zip64 ? (0xFFFF_FFFF, 0xFFFF_FFFF) : (UInt32(stored.count), UInt32(uncompressed))

            body.append(le32(0x0403_4B50))
            body.append(le16(20))
            body.append(le16(entry.flags))
            body.append(le16(entry.method))
            body.append(le16(0))
            body.append(le16(0x21))
            body.append(le32(crc))
            body.append(le32(size32.0))
            body.append(le32(size32.1))
            body.append(le16(UInt16(entry.name.count)))
            body.append(le16(0))
            body.append(contentsOf: entry.name)
            body.append(stored)

            central.append(centralRecord(of: entry, crc: crc, stored: stored.count, offset: offset))
        }
        var zip = body
        zip.append(central)
        zip.append(le32(0x0605_4B50))
        zip.append(le16(0))
        zip.append(le16(0))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le16(UInt16(entries.count)))
        zip.append(le32(UInt32(central.count)))
        zip.append(le32(UInt32(body.count)))
        zip.append(le16(0))
        return zip
    }

    /// 中央ディレクトリの 1 項目。ZIP64 なら大きさを拡張フィールド（`0x0001`）に書く
    private static func centralRecord(
        of entry: TestZipEntry,
        crc: UInt32,
        stored: Int,
        offset: Int
    ) -> Data {
        let uncompressed = entry.declaredSize ?? entry.content.count
        let size32: (UInt32, UInt32) = entry.zip64 ? (0xFFFF_FFFF, 0xFFFF_FFFF) : (UInt32(stored), UInt32(uncompressed))
        var extra = Data()
        if entry.zip64 {
            extra.append(le16(0x0001))
            extra.append(le16(16))
            extra.append(le64(UInt64(uncompressed)))
            extra.append(le64(UInt64(stored)))
        }
        var central = Data()
        central.append(le32(0x0201_4B50))
        central.append(le16(UInt16(entry.hostSystem) << 8 | 30))
        central.append(le16(20))
        central.append(le16(entry.flags))
        central.append(le16(entry.method))
        central.append(le16(0))
        central.append(le16(0x21))
        central.append(le32(entry.declaredCRC ?? crc))
        central.append(le32(size32.0))
        central.append(le32(size32.1))
        central.append(le16(UInt16(entry.name.count)))
        central.append(le16(UInt16(extra.count)))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le16(0))
        central.append(le32(entry.unixMode << 16))
        central.append(le32(UInt32(offset)))
        central.append(contentsOf: entry.name)
        central.append(extra)
        return central
    }

    private static func storedBytes(of entry: TestZipEntry) throws -> Data {
        guard entry.method == 8 else {
            return entry.content
        }
        // Foundation の `.zlib` はヘッダの無い raw Deflate（zip の中身と同じ形）
        return try (entry.content as NSData).compressed(using: .zlib) as Data
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
