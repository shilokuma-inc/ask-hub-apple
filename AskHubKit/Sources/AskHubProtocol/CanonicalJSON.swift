import Foundation

/// RFC 8785（JSON Canonicalization Scheme）で、JSON の値を 1 通りの文字列にそろえる。
///
/// 人の意図の封筒に署名するときと、署名を確かめるときに使う。Swift と Kotlin で同じバイト列になることを、
/// リポジトリの `protocol/vectors/canonical-json.json` のテスト用の例で確かめる。
/// - オブジェクトのキーは UTF-16 のコード単位の順に並べる
/// - 空白を入れない
/// - 文字列は `"` と `\` と U+0000〜U+001F だけをエスケープし、ほかの文字はそのまま UTF-8 で書く
/// - 数は整数だけ（`JSONValue` が小数を受け付けない）
public enum CanonicalJSON {
    public static func string(for value: JSONValue) -> String {
        var output = ""
        write(value, to: &output)
        return output
    }

    public static func data(for value: JSONValue) -> Data {
        Data(string(for: value).utf8)
    }

    private static func write(_ value: JSONValue, to output: inout String) {
        switch value {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .integer(value):
            output += String(value)
        case let .string(value):
            writeString(value, to: &output)
        case let .array(values):
            writeArray(values, to: &output)
        case let .object(members):
            writeObject(members, to: &output)
        }
    }

    private static func writeArray(_ values: [JSONValue], to output: inout String) {
        output += "["
        for (index, element) in values.enumerated() {
            if index > 0 { output += "," }
            write(element, to: &output)
        }
        output += "]"
    }

    private static func writeObject(_ members: [String: JSONValue], to output: inout String) {
        output += "{"
        let keys = members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for (index, key) in keys.enumerated() {
            if index > 0 { output += "," }
            writeString(key, to: &output)
            output += ":"
            if let member = members[key] {
                write(member, to: &output)
            }
        }
        output += "}"
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
