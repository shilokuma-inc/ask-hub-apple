import Foundation

/// テストで使う JSON Schema（draft 2020-12）の検証。
///
/// `protocol/schemas` で使うキーワードだけに対応し、知らないキーワードがあれば失敗にする（対応していない決まりを黙って見逃さないため）。
/// 外部の依存を足さないために、テストの中に置く。正規表現は NSRegularExpression で読む（ECMAScript と同じ範囲の書き方だけを使う前提）
final class SchemaValidator {
    enum Failure: Error, CustomStringConvertible {
        case unknownKeyword(String, schema: String)
        case unresolvedReference(String)
        case invalidSchema(String)

        var description: String {
            switch self {
            case let .unknownKeyword(keyword, schema): "対応していないキーワード \(keyword)（\(schema)）"
            case let .unresolvedReference(reference): "参照を解決できない: \(reference)"
            case let .invalidSchema(message): "スキーマが壊れている: \(message)"
            }
        }
    }

    static let annotations: Set = ["$schema", "$id", "title", "description", "$defs", "$comment", "format"]
    static let assertions: Set = [
        "type", "enum", "const", "properties", "required", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems",
        "minimum", "maximum", "minLength", "maxLength", "pattern", "$ref", "anyOf", "oneOf", "allOf", "not"
    ]

    private let directory: URL
    private var documents: [URL: Any] = [:]

    /// `directory` は `protocol/schemas`
    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// `reference` は `protocol/schemas` からの相対（`state/epic.schema.json`・`common.schema.json#/$defs/ulid` など）。合わない点を返す
    func errors(of instance: Any, against reference: String) throws -> [String] {
        let (schema, base) = try resolve(reference, from: directory.appendingPathComponent("_"))
        var errors: [String] = []
        try validate(instance, schema, base: base, path: "", errors: &errors)
        return errors
    }

    /// スキーマのファイルの中のすべての部分に、対応していないキーワードが無いかを確かめる
    func checkKeywords(in file: String) throws {
        try checkKeywords(load(directory.appendingPathComponent(file)), file: file)
    }

    // MARK: - 参照

    private func load(_ url: URL) throws -> Any {
        let url = url.standardizedFileURL
        if let document = documents[url] { return document }
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        documents[url] = document
        return document
    }

    /// `file#/pointer` を、`base`（今読んでいるスキーマのファイル）からの相対で解決する
    private func resolve(_ reference: String, from base: URL) throws -> (schema: Any, base: URL) {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = String(parts[0])
        let url = file.isEmpty ? base : base.deletingLastPathComponent().appendingPathComponent(file).standardizedFileURL
        var node = try load(url)
        let pointer = parts.count > 1 ? String(parts[1]) : ""
        for token in pointer.split(separator: "/") {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let object = node as? [String: Any], let next = object[key] else { throw Failure.unresolvedReference(reference) }
            node = next
        }
        return (node, url)
    }

    // MARK: - 検証

    private func validate(_ instance: Any, _ schema: Any, base: URL, path: String, errors: inout [String]) throws {
        if let schema = schema as? Bool {
            if !schema { errors.append("\(path): 置けない値") }
            return
        }
        guard let schema = schema as? [String: Any] else { throw Failure.invalidSchema("\(path) のスキーマがオブジェクトでない") }
        for keyword in schema.keys where !Self.annotations.contains(keyword) && !Self.assertions.contains(keyword) {
            throw Failure.unknownKeyword(keyword, schema: base.lastPathComponent)
        }
        if let reference = schema["$ref"] as? String {
            let (target, targetBase) = try resolve(reference, from: base)
            try validate(instance, target, base: targetBase, path: path, errors: &errors)
        }
        try validateGeneral(instance, schema, path: path, errors: &errors)
        try validateCombinations(instance, schema, base: base, path: path, errors: &errors)
        if let string = instance as? String, Self.jsonType(of: instance) == "string" {
            try validateString(string, schema, path: path, errors: &errors)
        }
        if let number = instance as? NSNumber, Self.jsonType(of: instance) != "boolean" {
            validateNumber(number, schema, path: path, errors: &errors)
        }
        if let array = instance as? [Any], Self.jsonType(of: instance) == "array" {
            try validateArray(array, schema, base: base, path: path, errors: &errors)
        }
        if let object = instance as? [String: Any], Self.jsonType(of: instance) == "object" {
            try validateObject(object, schema, base: base, path: path, errors: &errors)
        }
    }

    private func validateGeneral(_ instance: Any, _ schema: [String: Any], path: String, errors: inout [String]) throws {
        if let type = schema["type"] {
            let types = (type as? [String]) ?? [type as? String].compactMap { $0 }
            if !types.contains(where: { Self.matches(instance, type: $0) }) {
                errors.append("\(path): 型が \(types) でない（\(Self.jsonType(of: instance))）")
            }
        }
        if let values = schema["enum"] as? [Any], !values.contains(where: { Self.equal($0, instance) }) {
            errors.append("\(path): 決まった値のどれでもない")
        }
        if let value = schema["const"], !Self.equal(value, instance) { errors.append("\(path): 決まった値でない") }
    }

    private func validateCombinations(_ instance: Any, _ schema: [String: Any], base: URL, path: String, errors: inout [String]) throws {
        func passes(_ subschema: Any) throws -> Bool {
            var subErrors: [String] = []
            try validate(instance, subschema, base: base, path: path, errors: &subErrors)
            return subErrors.isEmpty
        }
        if let subschemas = schema["anyOf"] as? [Any], try !subschemas.contains(where: passes) {
            errors.append("\(path): anyOf のどれにも合わない")
        }
        if let subschemas = schema["oneOf"] as? [Any], try subschemas.filter(passes).count != 1 {
            errors.append("\(path): oneOf のちょうど 1 つに合わない")
        }
        for subschema in schema["allOf"] as? [Any] ?? [] {
            try validate(instance, subschema, base: base, path: path, errors: &errors)
        }
        if let subschema = schema["not"], try passes(subschema) { errors.append("\(path): not のスキーマに合ってしまう") }
    }

    private func validateString(_ string: String, _ schema: [String: Any], path: String, errors: inout [String]) throws {
        let length = string.unicodeScalars.count
        if let minimum = schema["minLength"] as? Int, length < minimum { errors.append("\(path): \(minimum) 文字より短い") }
        if let maximum = schema["maxLength"] as? Int, length > maximum { errors.append("\(path): \(maximum) 文字より長い") }
        if let pattern = schema["pattern"] as? String {
            let expression = try NSRegularExpression(pattern: pattern)
            if expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                errors.append("\(path): \(pattern) に合わない")
            }
        }
    }

    private func validateNumber(_ number: NSNumber, _ schema: [String: Any], path: String, errors: inout [String]) {
        if let minimum = schema["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue {
            errors.append("\(path): \(minimum) より小さい")
        }
        if let maximum = schema["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue {
            errors.append("\(path): \(maximum) より大きい")
        }
    }

    private func validateArray(_ array: [Any], _ schema: [String: Any], base: URL, path: String, errors: inout [String]) throws {
        if let minimum = schema["minItems"] as? Int, array.count < minimum { errors.append("\(path): \(minimum) 個より少ない") }
        if let maximum = schema["maxItems"] as? Int, array.count > maximum { errors.append("\(path): \(maximum) 個より多い") }
        if schema["uniqueItems"] as? Bool == true, Set(array.map(Self.canonical)).count != array.count {
            errors.append("\(path): 重複がある")
        }
        if let items = schema["items"] {
            for (index, element) in array.enumerated() {
                try validate(element, items, base: base, path: "\(path)[\(index)]", errors: &errors)
            }
        }
    }

    private func validateObject(_ object: [String: Any], _ schema: [String: Any], base: URL, path: String, errors: inout [String]) throws {
        for key in schema["required"] as? [String] ?? [] where object[key] == nil {
            errors.append("\(path).\(key): 必須の欄が無い")
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, value) in object {
            if let property = properties[key] {
                try validate(value, property, base: base, path: "\(path).\(key)", errors: &errors)
            } else if let additional = schema["additionalProperties"] {
                try validate(value, additional, base: base, path: "\(path).\(key)", errors: &errors)
            }
        }
    }

    // MARK: - キーワードの確認

    private func checkKeywords(_ schema: Any, file: String) throws {
        guard let schema = schema as? [String: Any] else { return }
        for keyword in schema.keys where !Self.annotations.contains(keyword) && !Self.assertions.contains(keyword) {
            throw Failure.unknownKeyword(keyword, schema: file)
        }
        let maps = ["properties", "$defs"].compactMap { schema[$0] as? [String: Any] }.flatMap { $0.values }
        let lists = ["anyOf", "oneOf", "allOf"].compactMap { schema[$0] as? [Any] }.flatMap { $0 }
        let singles = ["additionalProperties", "items", "not"].compactMap { schema[$0] }
        for subschema in maps + lists + singles {
            try checkKeywords(subschema, file: file)
        }
    }

    // MARK: - JSON の値

    static func jsonType(of value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            let double = number.doubleValue
            return double.isFinite && double.rounded() == double ? "integer" : "number"
        }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        let actual = Self.jsonType(of: value)
        return actual == type || (type == "number" && actual == "integer")
    }

    private static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        jsonType(of: lhs) == jsonType(of: rhs) && canonical(lhs) == canonical(rhs)
    }
}
