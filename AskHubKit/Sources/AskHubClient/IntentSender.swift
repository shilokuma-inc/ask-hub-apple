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

    /// 依頼。添付は参照（番号・名前・大きさ・ハッシュ）だけを書き、中身は `IntentSender.send(_:attachments:)` で意図より先に置く
    public static func request(repo: RepositoryFullName, title: String, body: String, attachments: [RequestAttachment] = []) -> Self {
        var payload: [String: JSONValue] = ["title": .string(title), "body": .string(body)]
        if !attachments.isEmpty {
            payload["attachments"] = .array(attachments.map(\.jsonValue))
        }
        return Self(kind: RequestIntent.kind, repo: repo, payload: payload)
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

    /// 対象から外す（終わっていない epic があれば司令塔が断る。状態リポジトリのファイルは残る）
    public static func removeRepository(_ repo: RepositoryFullName) -> Self {
        Self(kind: RemoveRepositoryIntent.kind, repo: repo)
    }

    /// ビルドの設定を入れる（対象に加えた後に送る。`repo.json` の `build` をまるごと置き換える）
    public static func configureRepository(_ repo: RepositoryFullName, build: RepositoryFile.Build) -> Self {
        Self(kind: ConfigureRepositoryIntent.kind, repo: repo, payload: ConfigureRepositoryIntent.payload(for: build))
    }

    /// 保護の設定を掛ける（司令塔が管理用のトークンで、ルールセット `askhub-protect` を掛け、重なる保護を外す。`ProtectionPolicy`）
    public static func applyProtection(_ repo: RepositoryFullName, requiredChecks: [String]) -> Self {
        Self(kind: ApplyProtectionIntent.kind, repo: repo, payload: ["requiredChecks": .array(requiredChecks.map(JSONValue.string))])
    }

    /// 開始する前の epic を取り下げる
    public static func abandonEpic(repo: RepositoryFullName, epic: ULID) -> Self {
        Self(kind: AbandonEpicIntent.kind, repo: repo, target: .init(type: EpicTarget.targetType, epic: epic))
    }

    /// 開始した epic を一時停止する（動いているジョブは最後まで終わらせ、次のジョブを作らない）
    public static func pauseEpic(repo: RepositoryFullName, epic: ULID) -> Self {
        Self(kind: PauseEpicIntent.kind, repo: repo, target: .init(type: EpicTarget.targetType, epic: epic))
    }

    /// 一時停止した epic を再開する
    public static func resumeEpic(repo: RepositoryFullName, epic: ULID) -> Self {
        Self(kind: ResumeEpicIntent.kind, repo: repo, target: .init(type: EpicTarget.targetType, epic: epic))
    }

    /// 開始した epic を、ほかの Mac（`mac`。オフラインでもよい）に引き継ぐ
    public static func handover(repo: RepositoryFullName, epic: ULID, to mac: MacName) -> Self {
        Self(
            kind: HandoverIntent.kind,
            repo: repo,
            target: .init(type: EpicTarget.targetType, epic: epic),
            payload: ["mac": .string(mac.rawValue)]
        )
    }

    /// 判断のカードへの答え（「別案にする」「直してほしい」は本文が要る）
    public static func decision(_ target: DecisionTarget, answer: DecisionsFile.Choice, note: String = "") -> Self {
        var payload: [String: JSONValue] = ["answer": .string(answer.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return Self(
            kind: DecisionIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: payload
        )
    }

    /// 最終 PR のマージの承認（見た head に結びつく）
    public static func approveMerge(_ target: FinalPullRequestTarget) -> Self {
        Self(kind: ApproveMergeIntent.kind, repo: target.repo, target: target.target, targetVersion: target.targetVersion)
    }

    /// 人がする作業を終えた（`file` の作業は、渡すファイルの参照を付け、中身は `IntentSender.send(_:attachments:)` で送る）
    public static func humanTaskDone(_ target: HumanTaskTarget, file: RequestAttachment? = nil) -> Self {
        Self(
            kind: HumanTaskDoneIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: file.map { ["attachments": .array([$0.jsonValue])] } ?? [:]
        )
    }

    /// 実機確認への答え（「問題あり」は説明が要る。直してほしいことは、別に依頼として送る）
    public static func verify(_ target: VerificationTarget, result: VerifyIntent.Result, note: String = "") -> Self {
        var payload: [String: JSONValue] = ["result": .string(result.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return Self(
            kind: VerifyIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: payload
        )
    }

    /// 配信した版のリリース文を確かめて、GitHub Release を公開する（`notes` は公開する本文。下書きのままでも、直したものでもよい）
    public static func publishGitHubRelease(_ target: ReleaseTarget, notes: String) -> Self {
        Self(
            kind: PublishGitHubReleaseIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: ["notes": .string(notes)]
        )
    }

    /// 最終 PR への指示
    public static func instructFinal(_ target: FinalPullRequestTarget, instruction: String) -> Self {
        Self(
            kind: InstructFinalIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: ["instruction": .string(instruction)]
        )
    }

    /// 人に渡したジョブをやり直させる（`target.attempt` は、見たときのジョブの試行の番号）
    public static func retry(_ target: JobTarget) -> Self {
        Self(kind: RetryJobIntent.kind, repo: target.repo, target: target.target, targetVersion: target.targetVersion)
    }

    /// 人に渡したジョブをやめる（先に進めなくなる epic は、epic ごとやめる）
    public static func giveUp(_ target: JobTarget) -> Self {
        Self(kind: GiveUpJobIntent.kind, repo: target.repo, target: target.target, targetVersion: target.targetVersion)
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
    /// 続けて送った意図の番号を、送った順に大きくする（司令塔は番号の順に処理するので、対象に加えてから依頼する、などの順を守る）
    private let nonces = NonceSequence()

    public init(store: any StateStore, key: DeviceSigningKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.key = key
        self.now = now
    }

    /// 送った意図（鍵と番号）を返す。同じ番号の意図がすでにあれば、上書きせずに失敗する。
    ///
    /// `attachments` は、意図の payload の `attachments` に書いた添付の中身（番号の順）。意図より先に `attachments/<device>/<nonce>/<n>` に置く
    /// （司令塔は意図を読んでから中身を読むので、中身の無い意図が読まれないようにする）
    @discardableResult
    public func send(_ draft: IntentDraft, attachments: [Data] = []) async throws(ClientError) -> IntentReference {
        let time = now()
        let nonce = await nonces.next(at: time)
        for (offset, data) in attachments.enumerated() {
            do {
                _ = try await store.write(
                    StatePath.attachment(device: key.keyID, nonce: nonce, number: offset + 1),
                    data: data,
                    replacing: nil,
                    message: "[attachment] \(draft.kind) \(offset + 1)"
                )
            } catch {
                throw .store(error)
            }
        }
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
        let path = StatePath.intent(device: key.keyID, nonce: nonce)
        let data = CanonicalJSON.data(for: stored)
        do {
            _ = try await store.write(path, data: data, replacing: nil, message: "[intent] \(draft.kind)")
        } catch {
            // 応答を受け取れなかった・読めなかったときは、GitHub が書いた後のことがある。読み直して同じ中身があれば、送れたことにする
            // （失敗として送り直すと、別の番号の同じ意図になる。2026-11-13、同じ回答が 2 回届いた）
            guard Self.mayHaveWritten(error), (try? await store.read(path))?.data == data else { throw .store(error) }
        }
        return IntentReference(keyId: key.keyID, nonce: nonce)
    }

    /// 書き込みが失敗に見えても、書けていることがある失敗（応答の前後で通信が切れた・応答を読めない・GitHub の障害・ぶつかった）
    static func mayHaveWritten(_ error: StateStoreError) -> Bool {
        switch error {
        case .transport, .unexpected, .serverError, .conflict:
            true
        case .rateLimited, .budgetExhausted, .unauthorized, .tokenUnavailable, .forbidden, .notFound, .redirected, .wrongKind, .invalidPath,
             .cancelled:
            false
        }
    }
}

/// 前に出した番号より必ず大きい番号を出す（同じミリ秒の中でも、乱数の部分で順が入れ替わらないように）
actor NonceSequence {
    private var last: ULID?

    func next(at time: Date) -> ULID {
        var candidate = ULID.generate(at: time)
        var shift = 0.001
        while let last, candidate <= last {
            candidate = ULID.generate(at: time.addingTimeInterval(shift))
            shift += 0.001
        }
        last = candidate
        return candidate
    }
}
