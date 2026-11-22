import Foundation

// 審査で断られた（リジェクト）ときの人の意図（`docs/renewal/release.md` の「リジェクト」）。対象は `{type: submission, id: <版>}` で、
// 版の今の状態に対してだけ意味を持つので `targetVersion` を書かない

/// リジェクトの理由を貼る人の意図（`kind` が `reportRejection`）。人が App Store Connect のアプリで見た審査の文（`text`）と、
/// 画面の画像（`attachments`。依頼の添付と同じ形・同じ置き場所 `attachments/<device>/<nonce>/<n>`・同じ上限）。どちらかは要る。
/// 司令塔は、AskHub で出して断られた版で、直し方をまだ選んでいなければ受け付け、常時オンの Mac の Claude に直し方の案を書かせる
public struct ReportRejectionIntent: Equatable, Sendable {
    public static let kind = "reportRejection"
    /// 理由の文の長さの上限（Unicode のコードポイント）
    public static let maximumTextLength = 10_000

    public var target: SubmissionTarget
    public var text: String
    public var attachments: [RequestAttachment]
    public var intent: IntentReference

    public init(target: SubmissionTarget, text: String, attachments: [RequestAttachment] = [], intent: IntentReference) {
        self.target = target
        self.text = text
        self.attachments = attachments
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, _) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: false)
        let reader = try PayloadReader(envelope.payload, allowed: ["text", "attachments"])
        let text = try reader.text("text", required: false, limit: Self.maximumTextLength)
        let attachments = try RequestIntent.readAttachments(reader.payload["attachments"])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw .init(detail: "理由の文か画像のどちらかが要る")
        }
        let intent = IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        self.init(target: target, text: text, attachments: attachments, intent: intent)
    }

    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        if !text.isEmpty { payload["text"] = .string(text) }
        if !attachments.isEmpty { payload["attachments"] = .array(attachments.map(\.jsonValue)) }
        return payload
    }
}

/// リジェクトの直し方を選ぶ人の意図（`kind` が `resolveRejection`）。`remedy` は `code`・`metadata`・`reply`。
/// Claude の案（か、案を書けなかった印）がある、今の断られた提出にだけ。司令塔は選んだ直し方を記録し、審査に出す中身を消して、
/// 人が確かめて「審査に出し直す」を押せるようにする（コードを直すなら、直した後に上げたビルドを待つ）。
/// コードを直すときの「このリリースを直す」依頼は、クライアントが別の依頼（`request` の `release`）として送る
public struct ResolveRejectionIntent: Equatable, Sendable {
    public static let kind = "resolveRejection"

    public var target: SubmissionTarget
    public var remedy: SubmissionFile.RejectionRemedy
    public var intent: IntentReference

    public init(target: SubmissionTarget, remedy: SubmissionFile.RejectionRemedy, intent: IntentReference) {
        self.target = target
        self.remedy = remedy
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, _) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: false)
        let reader = try PayloadReader(envelope.payload, allowed: ["remedy"])
        guard let remedy = SubmissionFile.RejectionRemedy(rawValue: try reader.text("remedy", required: true, limit: 16)) else {
            throw .init(detail: "remedy は code・metadata・reply のどれか")
        }
        self.init(target: target, remedy: remedy, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["remedy": .string(remedy.rawValue)] }
}
