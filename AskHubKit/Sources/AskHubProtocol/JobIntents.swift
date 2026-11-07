import Foundation

/// ジョブを対象にする人の意図の対象。`target` は `{type: job, epic, id: <ジョブ>}`、`targetVersion` は人が見たときの試行の番号（ジョブの `attempts`）
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
        guard let attempt = envelope.targetVersion.flatMap(AnswerIntent.version) else { throw .init(detail: "targetVersion が試行の番号でない") }
        self.init(repo: repo, epic: epic, job: job, attempt: attempt)
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

/// 人に渡したジョブをやめたときの扱い（`docs/renewal/flows.md` の「人に渡したジョブ」）。司令塔とクライアントで同じ扱いにする
public enum GiveUpEffect: Equatable, Sendable {
    /// やめると epic が先に進めなくなるので、epic ごとやめる（`abandoned`）
    case abandonsEpic
    /// ジョブだけをやめる
    case jobOnly
}

extension JobKind {
    /// やめたときの扱い。nil はやめられない（扱いは段階 3 で決める）
    public var giveUpEffect: GiveUpEffect? {
        switch self {
        case .makeQuestions, .reviseQuestion, .checkReadiness: .abandonsEpic
        case .explain, .reviseGoal: .jobOnly
        case .prepareWorkspace, .implementTask, .reviewTask, .fixTask, .integrateDevelop, .verifyBeforeFinal, .openFinalPullRequest,
             .reviewFinalPullRequest, .fixFinalPullRequest, .rerunChecks, .classifyDecisions, .captureScreenshots, .mergeFinalPullRequest,
             .cleanUp, .notify:
            nil
        }
    }
}
