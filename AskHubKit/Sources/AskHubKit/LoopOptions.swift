import Foundation

/// 自動ループで使える Claude のモデル。値は `claude --model` に渡すモデル ID
public enum LoopModel: String, CaseIterable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case fable = "claude-fable-5-1"

    /// 担当 PC の設定（`orchestrator.json` の `model`）を省略したときのモデル
    public static let standard = Self.opus

    /// 選択肢に出す名前
    public var title: String {
        switch self {
        case .opus: "Opus 5.5"
        case .sonnet: "Sonnet 5.5"
        case .fable: "Fable 5.1"
        }
    }
}

/// 自動ループで使える Claude のエフォート。値は `claude --effort` に渡す
public enum LoopEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    /// 選択肢に出す名前
    public var title: String {
        rawValue
    }
}

/// 自動ループのモデルとエフォートの指定。`nil` は担当 PC の設定のまま（指定しない）
///
/// アプリは「オーケストレーターで始める」とき、`ready-for-loop` を付ける前に、先頭に目印を置いたコメントで Discussion に残す:
///
/// ```html
/// <!-- ask-hub:loop-options model="claude-opus-5-5" effort="high" -->
/// このループは Opus 5.5・エフォート high で回します（AskHub から）。
/// ```
///
/// 起動スクリプト（`askhub-start-loop`）が新しい epic を準備するときに読み、準備・ループ本体・再開に使う。
/// 信用する author が書いた目印のうち、最後のものを使う。指定しない値は属性ごと省く
public struct LoopOptions: Sendable, Equatable {
    static let keyword = "ask-hub:loop-options"

    public var model: LoopModel?
    public var effort: LoopEffort?

    public init(model: LoopModel? = nil, effort: LoopEffort? = nil) {
        self.model = model
        self.effort = effort
    }

    /// 何も指定していない（コメントを付ける必要が無い）
    public var isDefault: Bool {
        model == nil && effort == nil
    }

    /// 人が読む説明。例: `Opus 5.5・エフォート high`
    public var summary: String {
        let model = model?.title ?? "担当 PC の既定のモデル"
        let effort = effort.map { "エフォート \($0.title)" } ?? "既定のエフォート"
        return "\(model)・\(effort)"
    }

    /// Discussion に付けるコメントの本文
    public var comment: String {
        var attributes: [String] = []
        if let model {
            attributes.append("model=\"\(model.rawValue)\"")
        }
        if let effort {
            attributes.append("effort=\"\(effort.rawValue)\"")
        }
        let marker = (["<!--", Self.keyword] + attributes + ["-->"]).joined(separator: " ")
        return """
            \(marker)
            このループは \(summary) で回します（AskHub から）。
            """
    }

    /// コメントの本文から読む。目印が先頭に無ければ `nil`。知らない値の属性は指定しなかったものとして扱う
    public static func parse(_ body: String) -> Self? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        let prefix = "<!-- \(keyword)"
        guard trimmed.hasPrefix(prefix), let end = trimmed.range(of: "-->") else {
            return nil
        }
        let inside = trimmed[trimmed.index(trimmed.startIndex, offsetBy: prefix.count)..<end.lowerBound]
        // 目印の直後は空白か閉じ（`ask-hub:loop-options-x` のような別の目印と取り違えない）
        guard inside.first.map({ $0.isWhitespace }) ?? true else {
            return nil
        }
        return Self(
            model: attribute("model", in: inside).flatMap(LoopModel.init(rawValue:)),
            effort: attribute("effort", in: inside).flatMap(LoopEffort.init(rawValue:))
        )
    }

    /// 信用する author が書いた目印のうち、最後のもの
    public static func latest(in comments: [(author: String?, body: String)], trustedAuthors: TrustedAuthors) -> Self? {
        comments.last { trustedAuthors.contains($0.author) && parse($0.body) != nil }.flatMap { parse($0.body) }
    }

    private static func attribute(_ name: String, in text: Substring) -> String? {
        guard let start = text.range(of: " \(name)=\"") else {
            return nil
        }
        let rest = text[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
