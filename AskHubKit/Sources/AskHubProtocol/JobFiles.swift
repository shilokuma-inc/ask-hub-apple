import Foundation

/// ジョブの種類（`docs/renewal/protocol.md` の最初の一覧）
public enum JobKind: String, Codable, Sendable, CaseIterable {
    case makeQuestions
    case explain
    case reviseQuestion
    case checkReadiness
    case reviseGoal
    case prepareWorkspace
    case implementTask
    /// 子 PR のチェックを待ち、読むだけのレビュー役の Claude が差分を読み、見た head を固定してマージする
    case reviewTask
    case fixTask
    case integrateDevelop
    case verifyBeforeFinal
    case openFinalPullRequest
    /// 最終 PR のチェックと信用するレビューの書き手を待ち、読むだけのレビュー役の Claude が epic 全体の差分を読む
    case reviewFinalPullRequest
    case fixFinalPullRequest
    case rerunChecks
    case classifyDecisions
    case captureScreenshots
    case mergeFinalPullRequest
    case cleanUp
    case notify
}

public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued
    case assigned
    case running
    case succeeded
    case failed
    /// 人の対応を待っている
    case waitingHuman
    /// Mac がオフラインなどで止めている。戻ったら再開する
    case paused
    case canceled
}

/// `repos/<owner>/<repo>/epics/<epic>/jobs/<job>.json`（ジョブ）。司令塔だけが書く。
///
/// ワーカーは、自分の試行のファイルに「始めた」を書くことで、ジョブを引き受けたことを示す。司令塔は試行を読んで `state` を更新する
public struct JobFile: StateFile {
    public static let formatVersion = 1

    /// ジョブが使うもの。Mac ごとの同時の上限（Claude・ビルド）に数える
    public struct Needs: Codable, Equatable, Sendable {
        public var claude: Bool
        public var build: Bool

        public init(claude: Bool, build: Bool) {
            self.claude = claude
            self.build = build
        }
    }

    public var id: ULID
    public var kind: JobKind
    public var repo: RepositoryFullName
    public var epic: ULID
    /// 対象のタスク（ゴールのタスクの id）。タスクに結びつかないジョブは nil
    public var task: String?
    /// 担当の Mac。決める前は nil
    public var assignedMac: MacName?
    public var needs: Needs
    /// 先に終わっている必要のあるジョブ
    public var dependsOn: [ULID]
    public var state: JobState
    /// これまでの試行の数
    public var attempts: Int
    /// 次に試してよい時刻（ランナー不足の待ち・利用上限の解除など）。すぐでよければ nil
    public var nextRunAt: Timestamp?
    /// kind ごとの入力（`docs/renewal/protocol.md` の表）
    public var input: [String: JSONValue]?
    /// ジョブの元になった人の意図。ワーカーは引き受ける前に、その意図の署名を自分でも確かめる
    public var origin: IntentReference?
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        id: ULID,
        kind: JobKind,
        repo: RepositoryFullName,
        epic: ULID,
        task: String? = nil,
        assignedMac: MacName? = nil,
        needs: Needs,
        dependsOn: [ULID] = [],
        state: JobState,
        attempts: Int = 0,
        nextRunAt: Timestamp? = nil,
        input: [String: JSONValue]? = nil,
        origin: IntentReference? = nil,
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.epic = epic
        self.task = task
        self.assignedMac = assignedMac
        self.needs = needs
        self.dependsOn = dependsOn
        self.state = state
        self.attempts = attempts
        self.nextRunAt = nextRunAt
        self.input = input
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if let task, task.isEmpty { violations.append("task が空") }
        if attempts < 0 { violations.append("attempts は 0 以上") }
        if dependsOn.contains(id) { violations.append("自分自身に依存している") }
        if Set(dependsOn).count != dependsOn.count { violations.append("dependsOn が重複している") }
        return violations
    }
}

public enum AttemptOutcome: String, Codable, Sendable, CaseIterable {
    case running
    case succeeded
    case failed
}

/// 失敗の区分（扱いは `docs/renewal/architecture.md` の表）
public enum FailureClass: String, Codable, Sendable, CaseIterable {
    case runnerUnavailable
    case flaky
    case buildFailed
    case testFailed
    case reviewRequired
    case conflict
    case usageLimit
    case authExpired
    case githubOutage
    /// Claude の API の障害（混み合い・5xx・つながらない）
    case claudeOutage
    case macOffline
    case timeout
    case unexpected
}

/// 試行の失敗
public struct AttemptFailure: Codable, Equatable, Sendable {
    public var failureClass: FailureClass
    public var message: String
    /// ログの抜粋。トークンらしい文字列を伏せてから書く
    public var logExcerpt: String?
    /// 再開してよい時刻（利用上限の解除の時刻など）。分からなければ nil
    public var retryAt: Timestamp?

    enum CodingKeys: String, CodingKey {
        case failureClass = "class"
        case message, logExcerpt, retryAt
    }

    public init(failureClass: FailureClass, message: String, logExcerpt: String? = nil, retryAt: Timestamp? = nil) {
        self.failureClass = failureClass
        self.message = message
        self.logExcerpt = logExcerpt
        self.retryAt = retryAt
    }
}

/// `repos/<owner>/<repo>/epics/<epic>/attempts/<job>/<n>.json`（試行）。実行した Mac のワーカーだけが書く
public struct AttemptFile: StateFile {
    public static let formatVersion = 1

    /// 外部の id。やり直す前に、すでにできているかを確かめるのに使う
    public struct Outputs: Codable, Equatable, Sendable {
        public var pullRequest: Int?
        public var commit: String?
        /// 作ったブランチ（作業場所の用意の作業ブランチなど）。`epic.json` には司令塔がこれを読んで書く
        public var branch: String?
        /// 子 PR のレビューの判定（`reviewTask`）
        public var verdict: ReviewVerdict?
        /// 直すこと（CI の失敗のログの抜粋・レビュー役の必須の指摘）。トークンらしい文字列は伏せてから書く
        public var findings: String?
        /// 実装と直しで Claude が報告したこと（`implementTask`・`fixTask`）
        public var report: TaskOutputReport?
        /// 最終 PR のレビューが見つけた、手動のマージの条件に当たるもの（`reviewFinalPullRequest`）
        public var mergeRisks: [MergeRisk]?
        /// 判断の仕分け（`classifyDecisions`）で見えるとした仮決めの id。ここに無いものは内部の細部。`decisions.json` には司令塔が写す
        public var visibleDecisions: [String]?
        /// 判断の仕分けで、見えるとした仮決めごとに選んだ撮る画面（仮決めの id → 撮れる画面の一覧の id）。合う画面が無い仮決めは載せない
        public var decisionScenes: [String: String]?
        /// 撮影（`captureScreenshots`）で撮った、仮決めごとの Before / After。`decisions.json` には司令塔が写す
        public var screenshots: [String: DecisionsFile.Screenshots]?
        /// 判断の仕分けで選んだ、epic 全体で見た目が変わった画面（撮れる画面の一覧の id）。`decisions.json` の `screens` に司令塔が写す
        public var changedScenes: [String]?
        /// 撮影で撮った、画面の変化の Before / After（`decisions.json` の `screens` と同じ形）
        public var screenChanges: [DecisionsFile.ScreenChange]?

        public init(
            pullRequest: Int? = nil,
            commit: String? = nil,
            branch: String? = nil,
            verdict: ReviewVerdict? = nil,
            findings: String? = nil,
            report: TaskOutputReport? = nil,
            mergeRisks: [MergeRisk]? = nil,
            visibleDecisions: [String]? = nil,
            decisionScenes: [String: String]? = nil,
            screenshots: [String: DecisionsFile.Screenshots]? = nil,
            changedScenes: [String]? = nil,
            screenChanges: [DecisionsFile.ScreenChange]? = nil
        ) {
            self.pullRequest = pullRequest
            self.commit = commit
            self.branch = branch
            self.verdict = verdict
            self.findings = findings
            self.report = report
            self.mergeRisks = mergeRisks
            self.visibleDecisions = visibleDecisions
            self.decisionScenes = decisionScenes
            self.screenshots = screenshots
            self.changedScenes = changedScenes
            self.screenChanges = screenChanges
        }
    }

    public struct Claude: Codable, Equatable, Sendable {
        /// 実際に使われたモデル（指定したモデルと違えば止める）
        public var model: String
        public var session: String?
        public var estimatedCostUsd: Double?

        public init(model: String, session: String? = nil, estimatedCostUsd: Double? = nil) {
            self.model = model
            self.session = session
            self.estimatedCostUsd = estimatedCostUsd
        }
    }

    public var job: ULID
    /// 何回目の試行か（1 から）
    public var number: Int
    public var mac: MacName
    public var startedAt: Timestamp
    /// 長い試行の途中で一定の間隔で書く。古いまま止まった試行は、司令塔が `macOffline` か `timeout` として扱う
    public var heartbeatAt: Timestamp
    public var endedAt: Timestamp?
    public var outcome: AttemptOutcome
    public var failure: AttemptFailure?
    public var outputs: Outputs?
    public var claude: Claude?

    enum CodingKeys: String, CodingKey {
        case number = "n"
        case job, mac, startedAt, heartbeatAt, endedAt, outcome, failure, outputs, claude
    }

    public init(
        job: ULID,
        number: Int,
        mac: MacName,
        startedAt: Timestamp,
        heartbeatAt: Timestamp,
        endedAt: Timestamp? = nil,
        outcome: AttemptOutcome,
        failure: AttemptFailure? = nil,
        outputs: Outputs? = nil,
        claude: Claude? = nil
    ) {
        self.job = job
        self.number = number
        self.mac = mac
        self.startedAt = startedAt
        self.heartbeatAt = heartbeatAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.failure = failure
        self.outputs = outputs
        self.claude = claude
    }

    public var violations: [String] {
        var violations: [String] = []
        if number < 1 { violations.append("n は 1 以上") }
        if heartbeatAt < startedAt { violations.append("heartbeatAt が startedAt より前") }
        if let endedAt, endedAt < startedAt { violations.append("endedAt が startedAt より前") }
        switch outcome {
        case .running:
            if endedAt != nil { violations.append("running なのに endedAt がある") }
        case .succeeded, .failed:
            if endedAt == nil { violations.append("終わったのに endedAt が無い") }
        }
        if (outcome == .failed) != (failure != nil) { violations.append("failure は failed のときだけ書く") }
        if let pullRequest = outputs?.pullRequest, pullRequest < 1 { violations.append("outputs.pullRequest は 1 以上") }
        if let commit = outputs?.commit, !Self.isCommitSHA(commit) { violations.append("outputs.commit の形が違う") }
        if let branch = outputs?.branch, !EpicFile.isBranchName(branch) { violations.append("outputs.branch の形が違う") }
        // JSON Schema の maxLength と同じく、Unicode のコードポイントで数える（結合文字を含む文で、書記素の数だけを見ると上限を超える）
        if let findings = outputs?.findings, findings.isEmpty || findings.unicodeScalars.count > Outputs.maximumFindingsLength {
            violations.append("outputs.findings は空でなく、\(Outputs.maximumFindingsLength) 文字まで")
        }
        if outputs?.verdict.map({ [.fixCI, .fixReview, .fixConflict].contains($0) }) == true, outputs?.findings == nil {
            violations.append("直す判定には findings が要る")
        }
        violations += outputs?.report?.problems ?? []
        if outputs?.mergeRisks?.contains(where: { $0.reason.isEmpty }) == true { violations.append("outputs.mergeRisks の reason が空") }
        if let visible = outputs?.visibleDecisions, !visible.allSatisfy(LocalIDs.isValid) || Set(visible).count != visible.count {
            violations.append("outputs.visibleDecisions の id の形が違うか、重なっている")
        }
        if let scenes = outputs?.decisionScenes,
           !scenes.keys.allSatisfy(LocalIDs.isValid) || !scenes.values.allSatisfy(ScreenshotScenesFile.isSceneID) {
            violations.append("outputs.decisionScenes の仮決めの id か画面の id の形が違う")
        }
        if let screenshots = outputs?.screenshots {
            if !screenshots.keys.allSatisfy(LocalIDs.isValid) { violations.append("outputs.screenshots の仮決めの id の形が違う") }
            violations += screenshots.sorted { $0.key < $1.key }.flatMap { id, shots in
                shots.problems.map { "outputs.screenshots.\(id): \($0)" }
            }
        }
        if let scenes = outputs?.changedScenes, !scenes.allSatisfy(ScreenshotScenesFile.isSceneID) || Set(scenes).count != scenes.count {
            violations.append("outputs.changedScenes の画面の id の形が違うか、重なっている")
        }
        if let screens = outputs?.screenChanges {
            violations += DecisionsFile(screens: screens).violations.map { "outputs.screenChanges: \($0)" }
        }
        if let model = claude?.model, model.isEmpty { violations.append("claude.model が空") }
        if let cost = claude?.estimatedCostUsd, !(cost >= 0) { violations.append("claude.estimatedCostUsd は 0 以上") }
        return violations
    }

    public static func isCommitSHA(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
