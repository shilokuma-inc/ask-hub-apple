import Foundation

/// ジョブを対象にする人の意図の対象。`target` は `{type: job, epic, id: <ジョブ>}`、`targetVersion` は人が見たときの試行の番号（ジョブの `attempts`）。
/// 試行の前に人に渡したジョブ（直しの上限を超えた直し）は 0
public struct JobTarget: Equatable, Sendable {
    public static let targetType = "job"

    public var repo: RepositoryFullName
    public var epic: ULID
    public var job: ULID
    /// 人が見たときの試行の番号。その後に試行が進んでいれば受け付けない
    public var attempt: Int

    public init(repo: RepositoryFullName, epic: ULID, job: ULID, attempt: Int) {
        self.repo = repo
        self.epic = epic
        self.job = job
        self.attempt = attempt
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic,
              let job = target.id.flatMap(ULID.init(rawValue:)) else {
            throw .init(detail: "target がジョブでない")
        }
        guard let attempt = envelope.targetVersion.flatMap(Self.attempt) else { throw .init(detail: "targetVersion が試行の番号でない") }
        self.init(repo: repo, epic: epic, job: job, attempt: attempt)
    }

    /// 0 以上の 10 進の整数（先頭の 0・符号を受け付けない）
    static func attempt(_ text: String) -> Int? {
        text == "0" ? 0 : AnswerIntent.version(text)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic, id: job.rawValue) }
    public var targetVersion: String { String(attempt) }
}

/// やり直しの人の意図（`kind` が `retry`）。人に渡したジョブを、もう一度試させる。payload は持たない
public struct RetryJobIntent: Equatable, Sendable {
    public static let kind = "retry"

    public var target: JobTarget
    public var intent: IntentReference

    public init(target: JobTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が retry でない") }
        let target = try JobTarget(envelope: envelope)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}

/// やめる人の意図（`kind` が `giveUp`）。人に渡したジョブをやめる。そのジョブが無いと先に進めない epic は、epic ごとやめる。payload は持たない
public struct GiveUpJobIntent: Equatable, Sendable {
    public static let kind = "giveUp"

    public var target: JobTarget
    public var intent: IntentReference

    public init(target: JobTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が giveUp でない") }
        let target = try JobTarget(envelope: envelope)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}

/// タスクを飛ばす人の意図（`kind` が `skipTask`）。人に渡した実装・レビュー・直しのジョブのタスクを飛ばし、epic は次のタスク・最終 PR へ進める。
/// payload は理由（`reason`）と任意のメモ（`note`）
public struct SkipTaskIntent: Equatable, Sendable {
    public static let kind = "skipTask"
    public static let maximumNoteLength = 2000

    public var target: JobTarget
    public var reason: TaskSkipReason
    /// 人のメモ。無ければ空
    public var note: String
    public var intent: IntentReference

    public init(target: JobTarget, reason: TaskSkipReason, note: String = "", intent: IntentReference) {
        self.target = target
        self.reason = reason
        self.note = note
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が skipTask でない") }
        let target = try JobTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["reason", "note"])
        guard let reason = TaskSkipReason(rawValue: try reader.text("reason", required: true, limit: 32)) else {
            throw .init(detail: "reason が handledElsewhere・notNeeded のどれでもない")
        }
        let note = try reader.text("note", required: false, limit: Self.maximumNoteLength)
        self.init(target: target, reason: reason, note: note, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { Self.payload(reason: reason, note: note) }

    /// 送る payload。メモは空なら書かない
    public static func payload(reason: TaskSkipReason, note: String) -> [String: JSONValue] {
        var payload: [String: JSONValue] = ["reason": .string(reason.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return payload
    }
}

/// 人に渡したジョブをやめたときの扱い（`docs/renewal/flows.md` の「人に渡したジョブ」）。司令塔とクライアントで同じ扱いにする
public enum GiveUpEffect: Equatable, Sendable {
    /// やめると epic が先に進めなくなるので、epic ごとやめる（`abandoned`）。開始した後なら、開いている子 PR と最終 PR を閉じる（ブランチは残す）
    case abandonsEpic
    /// ジョブだけをやめる
    case jobOnly
    /// 撮らずに先へ進む（同じ最終 PR と head でレビューする。判断のカードと画面の変化は「スクショ無し（撮影をやめた）」）
    case skipsScreenshots
}

extension JobKind {
    /// 開始の前の段取りのジョブ（質問づくり・質問の見直し・着手前の確認）
    static let planningKinds: Set<JobKind> = [.makeQuestions, .reviseQuestion, .checkReadiness]

    /// やめたときの扱い。nil はやめられない（作らない種類）
    public var giveUpEffect: GiveUpEffect? {
        switch self {
        case .makeQuestions, .reviseQuestion, .checkReadiness: .abandonsEpic
        // 実装と最終 PR の段取りは、どれが欠けても先に進めない（2026-11-12 のユーザーの決定）
        case .prepareWorkspace, .implementTask, .reviewTask, .fixTask, .verifyBeforeFinal, .classifyDecisions, .openFinalPullRequest,
             .reviewFinalPullRequest, .fixFinalPullRequest, .mergeFinalPullRequest:
            .abandonsEpic
        // 片付けの残りは、終わってから 1 日後の見回りで消える
        case .explain, .reviseGoal, .cleanUp: .jobOnly
        case .captureScreenshots: .skipsScreenshots
        // 名前だけで作らない種類
        case .integrateDevelop, .rerunChecks, .notify: nil
        }
    }

    /// タスクを飛ばせる種類か（実装・レビュー・直し）。司令塔とクライアントで同じ扱いにする
    public var skipsTask: Bool {
        [.implementTask, .reviewTask, .fixTask].contains(self)
    }

    /// epic の段階が `stage` のときに、人に渡したこのジョブのタスクを飛ばせるか（タスクを進めている `running` の epic だけ）
    public func canSkipTask(at stage: EpicStage) -> Bool {
        skipsTask && stage == .running
    }

    /// epic の段階が `stage` のときにやめた扱い。開始の前の段取りのジョブ（質問づくりなど）が開始した後の epic に残っていたら、
    /// epic は先に進めるので、ジョブだけをやめる（epic は開始の前の段階に戻せず、実装のジョブを止めることになる）
    public func giveUpEffect(at stage: EpicStage) -> GiveUpEffect? {
        guard Self.planningKinds.contains(self), [.running, .finalizing, .reviewing].contains(stage) else { return giveUpEffect }
        return .jobOnly
    }
}
