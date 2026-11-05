import Foundation

/// 人の意図が、その種類の形でない（理由つき）
public struct MalformedIntent: Error, Equatable, Sendable {
    public var detail: String

    public init(detail: String) {
        self.detail = detail
    }
}

/// 人の意図の `payload` を、知らない欄を許さずに読む（一部だけを指示として扱わない）
struct PayloadReader {
    let payload: [String: JSONValue]

    init(_ payload: [String: JSONValue]?, allowed: Set<String>) throws(MalformedIntent) {
        let payload = payload ?? [:]
        guard Set(payload.keys).isSubset(of: allowed) else { throw MalformedIntent(detail: "payload に知らない欄がある") }
        self.payload = payload
    }

    /// 文字列の欄。`required` なら空を受け付けない。長さは Unicode のコードポイントで数える（JSON Schema の maxLength と同じ）
    func text(_ name: String, required: Bool, limit: Int) throws(MalformedIntent) -> String {
        switch payload[name] {
        case nil where !required:
            return ""
        case let .string(text)? where text.unicodeScalars.count <= limit && !(required && text.isEmpty):
            return text
        default:
            throw MalformedIntent(detail: "\(name) が無い・空・長すぎる")
        }
    }
}
