import Foundation

// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の人の意図（`docs/renewal/creative-assets.md`）。
// どれも封筒の `repo` が対象のリポジトリで、`target` は `{ "type": "creative" }`、`targetVersion` は人が見たときの案の版（`creative.json` の
// `draft.revision`。案が無ければ `0`）。司令塔は `creative.json` に写し、Claude の案・書き出し・App Store Connect への書き込みは見回りが行う

extension CreativeIntents {
    /// 封筒の `target` の種類
    public static let targetType = "creative"

    /// 封筒の `repo`・`target`・`targetVersion`（案の版）を読む
    static func read(_ envelope: IntentEnvelope, kind: String) throws(MalformedIntent) -> (RepositoryFullName, Int) {
        guard envelope.kind == kind else { throw .init(detail: "kind が \(kind) でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == targetType, target.epic == nil, target.id == nil else {
            throw .init(detail: "target は {type: \(targetType)}")
        }
        guard let text = envelope.targetVersion, let revision = Int(text), revision >= 0, String(revision) == text else {
            throw .init(detail: "targetVersion は案の版（0 以上の整数）")
        }
        return (repo, revision)
    }
}

/// クリエイティブアセットの案を頼む・直してほしいことを書く人の意図（`kind` が `draftCreativeAssets`）。
/// `targetVersion` は人が見た案の版（案が無ければ `0`）。`comment` は直してほしいこと（最初の案なら省ける）。
/// 書き出しの途中に来たら、司令塔はその実行を取り消してから新しい案を書く
public struct DraftCreativeAssetsIntent: Equatable, Sendable {
    public static let kind = "draftCreativeAssets"

    public var repo: RepositoryFullName
    /// 人が見た案の版（案が無ければ 0）
    public var revision: Int
    /// 直してほしいこと（無ければ nil）
    public var comment: String?
    public var intent: IntentReference

    public init(repo: RepositoryFullName, revision: Int, comment: String? = nil, intent: IntentReference) {
        self.repo = repo
        self.revision = revision
        self.comment = comment
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (repo, revision) = try CreativeIntents.read(envelope, kind: Self.kind)
        let reader = try PayloadReader(envelope.payload, allowed: ["comment"])
        let comment: String?
        if reader.payload["comment"] == nil {
            comment = nil
        } else {
            comment = try reader.text("comment", required: true, limit: CreativeIntents.commentLimit)
        }
        self.init(repo: repo, revision: revision, comment: comment, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: CreativeIntents.targetType) }
    public var targetVersion: String { String(revision) }
    public var payload: [String: JSONValue] { Self.payload(comment: comment) }

    /// 送る payload（クライアントが作る）
    public static func payload(comment: String?) -> [String: JSONValue] {
        guard let comment else { return [:] }
        return ["comment": .string(comment)]
    }
}

/// 書き出した案を承認する人の意図（`kind` が `approveCreativeAssets`）。`targetVersion` は人が見た案の版で、書き出しが終わった
/// （`rendered`）今の案だけ受け付ける。承認した案は、次のリリースの「審査に出す」で版の言語に置く。payload は持たない
public struct ApproveCreativeAssetsIntent: Equatable, Sendable {
    public static let kind = "approveCreativeAssets"

    public var repo: RepositoryFullName
    /// 人が見た案の版（1 以上）
    public var revision: Int
    public var intent: IntentReference

    public init(repo: RepositoryFullName, revision: Int, intent: IntentReference) {
        self.repo = repo
        self.revision = revision
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (repo, revision) = try CreativeIntents.read(envelope, kind: Self.kind)
        guard revision >= 1 else { throw .init(detail: "承認する案の版は 1 以上") }
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(repo: repo, revision: revision, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: CreativeIntents.targetType) }
    public var targetVersion: String { String(revision) }
    public var payload: [String: JSONValue] { [:] }
}
