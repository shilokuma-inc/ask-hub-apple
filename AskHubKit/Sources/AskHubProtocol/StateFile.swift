import Foundation

/// 状態リポジトリの 1 つのファイルの型（`docs/renewal/protocol.md` の「状態リポジトリ」）。
///
/// どのファイルも、形の版を `v` に持つ。`v` は型に持たせず、`StateFileCoder` が読むときに確かめ、書くときに足す。
public protocol StateFile: Codable, Equatable, Sendable {
    /// このファイルの形の版。欄の意味を変える・欄を消す・必須の欄を足すときに上げる。
    /// 任意の欄や列挙の値を足すときは上げない（読む側は知らない欄を読み飛ばし、知らない列挙の値は読めないファイルとして知らせる）
    static var formatVersion: Int { get }

    /// 型だけでは表せない決まり（数の範囲・欄どうしの関係など）に合わない点。空なら合っている
    var violations: [String] { get }
}

extension StateFile {
    public var violations: [String] { [] }
}

public enum StateFileError: Error, Equatable, Sendable {
    /// JSON として読めない
    case notJSON
    /// `v` が無い
    case missingVersion
    /// 知らない版。読まずに知らせる
    case unsupportedVersion(Int)
    /// 欄が欠けている・値の形が違う・決まりに合わない
    case malformed(String)
}

/// 状態リポジトリのファイルを読み書きする
public enum StateFileCoder {
    /// 読む。`v` を先に確かめ、知らない版なら中身を読まない
    public static func decode<File: StateFile>(_ type: File.Type = File.self, from data: Data) throws(StateFileError) -> File {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            throw .notJSON
        } catch {
            throw .malformed(describe(error))
        }
        guard let version = probe.version else { throw .missingVersion }
        guard version == File.formatVersion else { throw .unsupportedVersion(version) }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw .malformed(describe(error))
        }
        guard file.violations.isEmpty else { throw .malformed(file.violations.joined(separator: "、")) }
        return file
    }

    /// 書く。決まりに合わないファイルは書かない。差分を読みやすいよう、キーを並べて字下げし、末尾に改行を置く
    public static func encode<File: StateFile>(_ file: File) throws -> Data {
        guard file.violations.isEmpty else { throw StateFileError.malformed(file.violations.joined(separator: "、")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Versioned(file: file))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])): 欄が無い"
        @unknown default:
            return "\(error)"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.isEmpty ? "(最上位)" : codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

private enum VersionKey: String, CodingKey {
    case version = "v"
}

private struct VersionProbe: Decodable {
    let version: Int?

    init(from decoder: any Decoder) throws {
        version = try decoder.container(keyedBy: VersionKey.self).decodeIfPresent(Int.self, forKey: .version)
    }
}

/// ファイルの欄と同じ階層に `v` を足して書く
private struct Versioned<File: StateFile>: Encodable {
    let file: File

    func encode(to encoder: any Encoder) throws {
        try file.encode(to: encoder)
        var container = encoder.container(keyedBy: VersionKey.self)
        try container.encode(File.formatVersion, forKey: .version)
    }
}
