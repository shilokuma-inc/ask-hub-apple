import AskHubProtocol
import Foundation

/// Claude に返してもらう形（JSON Schema）。形はここで決め、数や欄どうしの決まりは各ジョブの `problems(in:)` で確かめる
enum OutputSchema {
    static func object(_ properties: [String: JSONValue], required: [String]? = nil) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array((required ?? properties.keys.sorted()).map(JSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func array(of items: JSONValue, _ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": items, "description": .string(description)])
    }

    static func nullable(_ schema: JSONValue) -> JSONValue {
        .object(["anyOf": .array([schema, .object(["type": .string("null")])])])
    }

    static func oneOf(_ values: [String], _ description: String) -> JSONValue {
        .object(["enum": .array(values.map(JSONValue.string)), "description": .string(description)])
    }

    static let option = object([
        "label": string("選択肢の短い名前（30 文字程度まで）"),
        "effect": string("この選択肢を選ぶと何が変わるか")
    ])

    static let caution = nullable(object([
        "kind": oneOf(Caution.Kind.allCases.map(\.rawValue), "security・privacy・irreversible・cost のどれか"),
        "reason": string("この判断で何に気をつけてほしいか")
    ]))

    /// 質問の中身（質問づくりの案と書き直しの案で共通の欄）
    static let questionContent: [String: JSONValue] = [
        "title": string("質問の題"),
        "why": string("なぜ決める必要があるか"),
        "options": array(of: option, "選択肢（2〜4 個）"),
        "recommended": string("推奨の選択肢の label"),
        "reason": string("推奨の理由"),
        "caution": caution
    ]

    static let questionDraft = object(questionContent.merging([
        "id": string("q1・q2 のような id（英小文字で始まり、英小文字・数字・ハイフン）"),
        "dependsOn": array(of: string("前提にする質問の id"), "答えを前提にする質問の id。無ければ空")
    ]) { first, _ in first }, required: ["id", "title", "why", "options", "recommended", "reason", "dependsOn"])

    static let questionRewrite = object(questionContent.merging([
        "change": string("書き直した理由")
    ]) { first, _ in first }, required: ["title", "why", "options", "recommended", "reason", "change"])
}
