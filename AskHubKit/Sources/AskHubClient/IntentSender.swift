import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// クライアントと非常口の失敗。秘密の値は含めない
public enum ClientError: Error, Equatable, Sendable {
    case store(StateStoreError)
    case signing(DeviceSigningKey.Failure)
    /// 公開鍵の記録が、足す前の形として合わない（連番の抜け・最初の鍵がもうある など）
    case ledger(String)
    case malformed(String)
}

/// 人の意図の中身（封筒の `kind`・対象・版・`payload`）。送るときに、番号・時刻・鍵を足して署名する
public struct IntentDraft: Equatable, Sendable {
    public var kind: String
    public var repo: RepositoryFullName?
    public var target: IntentEnvelope.Target?
    public var targetVersion: String?
    public var payload: [String: JSONValue]

    public init(
        kind: String,
        repo: RepositoryFullName? = nil,
        target: IntentEnvelope.Target? = nil,
        targetVersion: String? = nil,
        payload: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.repo = repo
        self.target = target
        self.targetVersion = targetVersion
        self.payload = payload
    }

    /// 依頼（添付は、置き方を決めてから足す）
    public static func request(repo: RepositoryFullName, title: String, body: String) -> Self {
        Self(kind: "request", repo: repo, payload: ["title": .string(title), "body": .string(body)])
    }

    /// 回答。`choice` は選択肢の label（自由記述だけなら nil）
    public static func answer(_ question: QuestionTarget, choice: String?, note: String) -> Self {
        var payload: [String: JSONValue] = ["mode": .string("answer"), "note": .string(note)]
        if let choice { payload["choice"] = .string(choice) }
        return question.draft(payload: payload)
    }

    /// 説明を求める
    public static func clarify(_ question: QuestionTarget, note: String) -> Self {
        question.draft(payload: ["mode": .string("clarify"), "note": .string(note)])
    }

    public static func startEpic(_ target: EpicTarget, mac: MacName) -> Self {
        epic(StartEpicIntent.kind, target, payload: ["mac": .string(mac.rawValue)])
    }

    public static func reviseGoal(_ target: EpicTarget, instruction: String) -> Self {
        epic(ReviseGoalIntent.kind, target, payload: ["instruction": .string(instruction)])
    }

    public static func decideSplit(_ target: EpicTarget, choice: DecideSplitIntent.Choice) -> Self {
        epic(DecideSplitIntent.kind, target, payload: ["choice": .string(choice.rawValue)])
    }

    /// 対象に加える
    public static func addRepository(_ repo: RepositoryFullName, platform: RepositoryPlatform = .apple) -> Self {
        Self(kind: AddRepositoryIntent.kind, repo: repo, payload: ["platform": .string(platform.rawValue)])
    }

    private static func epic(_ kind: String, _ target: EpicTarget, payload: [String: JSONValue]) -> Self {
        Self(kind: kind, repo: target.repo, target: target.target, targetVersion: target.targetVersion, payload: payload)
    }
}

/// 回答する質問（リポジトリ・epic・質問の id と、読んだときの質問の版）
public struct QuestionTarget: Equatable, Sendable {
    public var repo: RepositoryFullName
    public var epic: ULID
    public var question: String
    public var version: Int

    public init(repo: RepositoryFullName, epic: ULID, question: String, version: Int) {
        self.repo = repo
        self.epic = epic
        self.question = question
        self.version = version
    }

    func draft(payload: [String: JSONValue]) -> IntentDraft {
        let target = IntentEnvelope.Target(type: AnswerIntent.targetType, epic: epic, id: question)
        return IntentDraft(kind: AnswerIntent.kind, repo: repo, target: target, targetVersion: String(version), payload: payload)
    }
}

/// 人の意図を署名し、状態リポジトリの `intents/<端末の鍵>/<番号>.json` に置く（クライアントと非常口で使う）
public struct IntentSender: Sendable {
    public var store: any StateStore
    public var key: DeviceSigningKey
    public var now: @Sendable () -> Date

    public init(store: any StateStore, key: DeviceSigningKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.key = key
        self.now = now
    }

    /// 送った意図（鍵と番号）を返す。同じ番号の意図がすでにあれば、上書きせずに失敗する
    @discardableResult
    public func send(_ draft: IntentDraft) async throws(ClientError) -> IntentReference {
        let time = now()
        let nonce = ULID.generate(at: time)
        let envelope = IntentEnvelope(
            kind: draft.kind,
            repo: draft.repo,
            target: draft.target,
            targetVersion: draft.targetVersion,
            payload: draft.payload,
            issuedAt: Timestamp(time),
            nonce: nonce,
            keyId: key.keyID
        )
        let value: JSONValue
        do {
            value = try envelope.jsonValue()
        } catch {
            throw .malformed("封筒を作れない（\(error)）")
        }
        let signature: String
        do {
            signature = try key.sign(value)
        } catch {
            throw .signing(error)
        }
        let stored = JSONValue.object(["envelope": value, "sig": .string(signature)])
        do {
            _ = try await store.write(
                StatePath.intent(device: key.keyID, nonce: nonce),
                data: CanonicalJSON.data(for: stored),
                replacing: nil,
                message: "[intent] \(draft.kind)"
            )
        } catch {
            throw .store(error)
        }
        return IntentReference(keyId: key.keyID, nonce: nonce)
    }
}
