import Foundation

/// 司令塔が掛けるブランチの保護（ルールセット）の決まり（`docs/renewal/security.md` の「ブランチ保護」）。
///
/// develop・main・`release/` の下のすべてのブランチに、PR 必須・必須のチェック・force push と削除の禁止を、例外なしで掛ける。
/// 人がクライアントで「保護の設定」を押したとき（`applyProtection`）だけ、司令塔が管理用のトークンで掛ける
public enum ProtectionPolicy {
    /// ルールセットの名前。同じ名前のリポジトリのルールセットがあれば、置き換える
    public static let rulesetName = "askhub-protect"
    /// 守るブランチ（ルールセットの `refs/heads/` の後ろ）。GitHub のパターン（`File::FNM_PATHNAME`）では、末尾の `**` は `/` をまたがず
    /// `**/` だけがまたぐので、`release/` の下を深さによらず守るには `release/**/*` にする（`release/1.0` も `release/mobile/1.0` も合う）
    public static let branches = ["develop", "main", "release/**/*"]
    /// 必須のチェックの既定（ビルドの設定の `childChecks` が無いとき）
    public static let defaultRequiredChecks = ["build / build"]
    /// 必須のチェックを出してよいアプリ（GitHub Actions）。ほかのアプリや commit status で同じ名前を出しても通らない
    public static let githubActionsAppID = 15_368
    /// 必須のチェックの数の上限
    public static let maxRequiredChecks = 20
    /// チェックの名前の長さの上限（Unicode のコードポイント）
    public static let maxCheckNameLength = 200

    /// カンマ区切りの必須のチェックの名前（非常口の `--checks`）。かっこの中のカンマでは分けない（行列のジョブの名前
    /// `test (macOS, debug)` を 1 つの名前のままにする）。前後の空白は除く。空の名前があれば nil（打ち間違いを黙って捨てない）
    public static func checks(fromList text: String) -> [String]? {
        var checks: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "(": depth += 1
            case ")": depth = max(depth - 1, 0)
            case "," where depth == 0:
                checks.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        checks.append(current)
        let trimmed = checks.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmed.contains(where: \.isEmpty) ? nil : trimmed
    }

    /// 必須のチェックの名前の並びの問題。1 つ以上・重ならない・空でない・制御文字を含まない・長すぎない
    public static func problems(ofRequiredChecks checks: [String]) -> [String] {
        var problems: [String] = []
        if checks.isEmpty { problems.append("必須のチェックが無い（1 つ以上要る）") }
        if checks.count > maxRequiredChecks { problems.append("必須のチェックは \(maxRequiredChecks) 個まで") }
        if Set(checks).count != checks.count { problems.append("必須のチェックが重なっている") }
        for check in checks {
            let scalars = check.unicodeScalars
            if check.trimmingCharacters(in: .whitespaces).isEmpty || scalars.count > maxCheckNameLength
                || scalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                problems.append("必須のチェックの名前の形が違う（空・長すぎる・制御文字）")
                break
            }
        }
        return problems
    }
}

/// 保護の設定を掛ける人の意図（`applyProtection`）。封筒の `repo` が対象のリポジトリ（対象に加えた後に送る）。
/// `target`・`targetVersion` は持たず、送るたびにルールセット `askhub-protect` を決まりの形に置き換える（`ProtectionPolicy`）
public struct ApplyProtectionIntent: Equatable, Sendable {
    public static let kind = "applyProtection"

    public var repo: RepositoryFullName
    /// 必須にするチェックの名前（REST の check run の `name`。再利用ワークフローのジョブは `build / build` の形）
    public var requiredChecks: [String]
    public var intent: IntentReference

    public init(repo: RepositoryFullName, requiredChecks: [String], intent: IntentReference) {
        self.repo = repo
        self.requiredChecks = requiredChecks
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が applyProtection でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "保護の設定に target か targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["requiredChecks"])
        guard case let .array(values)? = reader.payload["requiredChecks"] else { throw .init(detail: "requiredChecks が無い") }
        var checks: [String] = []
        for value in values {
            guard case let .string(check) = value else { throw .init(detail: "requiredChecks に文字列でないものがある") }
            checks.append(check)
        }
        let problems = ProtectionPolicy.problems(ofRequiredChecks: checks)
        guard problems.isEmpty else { throw .init(detail: problems.joined(separator: "、")) }
        self.init(repo: repo, requiredChecks: checks, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] {
        ["requiredChecks": .array(requiredChecks.map(JSONValue.string))]
    }
}
