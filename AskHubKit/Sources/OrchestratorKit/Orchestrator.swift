import AskHubKit
import Foundation

/// epic の最終 PR（`epic-final` が付いた open な PR）
public struct EpicFinalPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    /// epic ブランチ
    public let headBranch: String
    /// 作った人。削除済みのユーザーでは `nil`
    public let author: String?
    /// 本文の先頭のゴール元の Discussion の目印（`<!-- ask-hub:discussion N -->`）の番号。無ければ `nil`
    public let goalDiscussion: Int?

    public init(repository: String, number: Int, headBranch: String, author: String?, goalDiscussion: Int? = nil) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.author = author
        self.goalDiscussion = goalDiscussion
    }
}

/// 既にある PR
public struct ExistingPullRequest: Sendable, Equatable {
    public let number: Int
    public let isOpen: Bool
    /// PR の本文。空なら `nil`
    public let body: String?
    /// マージ済み
    public let isMerged: Bool

    public init(number: Int, isOpen: Bool, body: String? = nil, isMerged: Bool = false) {
        self.number = number
        self.isOpen = isOpen
        self.body = body
        self.isMerged = isMerged
    }
}

/// 「ポーリング → 状態判定 → アクション」を繰り返す。
/// 起動した Discussion（`LaunchTracker`）と回答済みの質問（`ResumeWatcher`）を覚えておくため actor にする
public actor Orchestrator {
    /// 今の設定。`configStore` があれば、ポーリングのたびに読み直す
    var config: OrchestratorConfig
    /// 設定の読み直しと担当リポジトリの書き換え。`nil` なら起動時の設定のまま動く
    let configStore: (any OrchestratorConfigStore)?
    /// 最後に読み直しに失敗した理由。同じ失敗をポーリングのたびにログに出さない
    var lastReloadFailure: String?
    /// 担当リポジトリごとの信用する author。ポーリングのはじめに求め直す
    var trust: TrustDirectory
    /// このポーリングで取得した `manual-loop` の open な Discussion。取得に失敗したら `nil`
    var manualLoops: [ManualLoopDiscussion]?
    /// 手動ループ（信用する author の open な `manual-loop` の Discussion）の番号。キーはリポジトリ（`fullName` の小文字）。
    /// 取得に失敗したポーリングでは前回の値を使う
    var manualLoopNumbers: [String: Set<Int>] = [:]
    /// 手動ループがあるリポジトリ（`fullName` の小文字）
    var manualLoopRepositories: Set<String> {
        Set(manualLoopNumbers.keys)
    }
    /// 制御用 worktree を別の epic に戻すのを待っていることをログに出した指示（`<repo小文字>#<コメント id>`）。待つ間、同じことを毎回出さない
    var loggedRestoreWaits: Set<String> = []
    /// 担当リポジトリに書き込み権限を持つアカウントの取得元。`nil` なら設定の一覧だけを信用する
    let repositoryWriters: RepositoryWriters?
    let github: any OrchestratorGitHub
    private let inbox: any InboxSource
    let runtime: any LoopRuntime
    let log: @Sendable (String) -> Void
    var tracker = LaunchTracker()
    private var watcher = ResumeWatcher()
    /// epic の最終 PR を作った（または既にあった）epic（キーは `<repo小文字> <epic ブランチ>`）。毎回 GitHub に問い合わせないために覚える
    var finalizedEpics: Set<String> = []
    /// GitHub の情報から最終 PR を作れるかを最後に確かめた時刻（キーは `<repo小文字> <epic ブランチ>`）と、
    /// 手動ループの完了を見るために状態用の Issue を最後に読んだ時刻（キーは `<repo小文字>`）
    var fallbackFinalChecks: [String: Date] = [:]
    /// 仮決め一覧・最終 PR への指示を受けてループを再開した epic。再び完了したら、最終 PR の本文を書き直す
    var epicsToRefresh: Set<String> = []
    /// 処理済みとして扱う仮決め一覧・最終 PR のコメント（`<repo小文字>#<コメント id>`）。同じコメントで何度も再開しない。
    /// ループの開始を確かめてから（または上限まで試して諦めてから）入れる
    var resumedInstructionComments: Set<String> = []
    /// 仮決め一覧・最終 PR への指示でループを起動し、開始をまだ確かめていないもの（キーは担当リポジトリの `fullName` を小文字にしたもの）
    var pendingInstructionResumes: [String: InstructionResume] = [:]
    /// 担当の印を最後に書いた時刻（キーは担当リポジトリの `fullName` を小文字にしたもの）
    var lastHeartbeats: [String: Date] = [:]
    /// Claude の利用上限の解除の時刻。それまでこの Mac のループの起動・再開を止める（アカウントは Mac ごとに共通）
    var usageLimitedUntil: Date?
    let now: @Sendable () -> Date
    var ideaTracker = IdeaRequestTracker()
    var repositoryRequestTracker = RepositoryRequestTracker()
    var conflictTracker = ConflictTracker()
    /// 裏で実行中の最終 PR のコンフリクトの解消（キーはリポジトリの `owner/name` の小文字。同じリポジトリでは 1 件ずつ）
    var conflictResolutions: [String: Task<Void, Never>] = [:]
    /// 最後に取得した、コンフリクトした最終 PR。解消が終わったリポジトリで、次の PR をポーリングを待たずに始めるのに使う
    var conflictingPullRequests: [ConflictingPullRequest] = []
    /// 裏の解消が終わるのを待っている（`--once`・`run` の終わり）。その間は新しい解消を始めない
    var drainsConflictResolutions = false
    /// 最終 PR の第三者レビュー・修正の進み具合（Discussion #503）
    var finalReviewTracker = FinalReviewTracker()
    /// 裏で実行中の第三者レビュー・修正。キーはリポジトリ名の小文字
    var finalReviews: [String: Task<Void, Never>] = [:]
    /// 最後に取得した第三者レビューの対象。終わった直後に、同じリポジトリの次の PR を始めるのに使う
    var finalReviewCandidates: [FinalReviewCandidate] = []
    /// 最終 PR に書き出した第三者レビューの進み具合（キーは PR）。同じ内容は書き直さない
    var publishedFinalReviews: [String: FinalReviewMarker] = [:]
    /// 最終 PR の状態コメントの id（キーは PR）。見つけたものと作ったもの
    var finalReviewStatusComments: [String: Int] = [:]
    /// 状態コメントを書き出している PR。actor の再入（ポーリングと裏の処理の終わりが重なる）でコメントを二重に作らない
    var publishingFinalReviews: Set<String> = []
    /// 書き換えられなかった（消された・権限が無い）状態コメントの id。探すときに選ばない
    var unusableFinalReviewComments: Set<Int> = []
    var stallWatcher = StallWatcher()
    /// 状態用の Issue に書いた内容
    var loopStatusPublisher = LoopStatusPublisher()
    /// xcb のイベントログから組み立てたビルドの情報。設定の `buildHosts` が無ければ `nil`
    var buildActivity: BuildActivity?
    /// ビルドの Mac の状態の Issue に書いた内容
    var buildHostsPublisher = BuildHostsPublisher()
    /// 最後に取れた `xcb status --json` と、取った時刻
    var lastXcbStatus: (status: XcbStatus, measuredAt: Date)?
    /// 最後に `xcb status --json` を呼んだ時刻（失敗したときも含む）
    var lastXcbStatusAttemptAt: Date?
    let xcbStatus: any XcbStatusFetching
    /// 担当リポジトリごとの、制御用 worktree が準備を終えていない `ready-for-loop` の Discussion の番号（最後に取得できたもの。手動ループ・信用しない author のものを除く）。
    /// 起動してからまだ一度も取得できていなければ `nil`（開始待ちのループのコメントを、終わったものとして消さない）
    var readyDiscussionNumbers: [String: [Int]]?
    /// epic の最終 PR がマージ済みか（キーは `<repo小文字> <branch>`）。未マージなら確かめた時刻も持ち、問い合わせを間引く
    var epicMergeChecks: [String: (merged: Bool, checkedAt: Date)] = [:]

    /// 依頼から Discussion を作らせるコマンドの制限時間
    static let ideaCommandTimeout: Duration = .seconds(30 * 60)

    /// - Parameters:
    ///   - inbox: `needs-answer` の Discussion / PR と質問の取得元
    ///   - configStore: 設定の読み直しと担当リポジトリの書き換え（担当リポジトリの作成・削除の依頼に使う）
    ///   - repositoryWriters: 担当リポジトリに書き込み権限を持つアカウントの取得元（設定の `trustRepositoryWriters` が有効なときに使う）
    ///   - xcbStatus: `xcb status --json` の呼び出し（設定の `buildHosts` があるときだけ使う）
    public init(
        config: OrchestratorConfig,
        github: any OrchestratorGitHub,
        inbox: any InboxSource,
        runtime: any LoopRuntime,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        configStore: (any OrchestratorConfigStore)? = nil,
        repositoryWriters: RepositoryWriters? = nil,
        xcbStatus: any XcbStatusFetching = XcbStatusCommand()
    ) {
        self.config = config
        self.xcbStatus = xcbStatus
        self.configStore = configStore
        self.trust = TrustDirectory(base: config.trustedAuthors)
        self.repositoryWriters = repositoryWriters
        self.github = github
        self.inbox = inbox
        self.runtime = runtime
        self.log = log
        self.now = now
    }

    /// `pollInterval` ごとにポーリングする。タスクがキャンセルされるまで戻らない。
    /// 1 回のポーリングの失敗（ネットワークの断など）はログに出して次の回に持ち越す。
    /// 戻る前に、裏で実行中の最終 PR のコンフリクトの解消が終わるのを待つ
    public func run(sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            do {
                try await pollOnce()
            } catch {
                log("ポーリングに失敗しました: \(error)")
            }
            do {
                try await sleep(config.pollInterval)
            } catch {
                break
            }
        }
        await waitForConflictResolutions()
    }

    /// 1 回分のポーリング。実行した起動判定を返す
    @discardableResult
    public func pollOnce() async throws -> [LaunchDecision] {
        // 手で書き換えた設定・担当リポジトリごとの信用する author（書き込み権限を持つアカウント）・手動ループを、再起動せずに反映する
        await preparePoll()
        // 固まったループを止める（止めた後は、異常終了したループとして再開する）
        await terminateHungLoops()
        var statuses: [String: LoopStatus] = [:]
        for repository in config.repositories {
            statuses[repository.fullName.lowercased()] = await runtime.status(of: repository)
        }
        // 止まったループが Claude の利用上限で終わっていたら、解除の時刻を担当の印に書いて待つ
        await refreshUsageLimit(statuses: statuses)
        await updateHeartbeats()
        if activeUsageLimit(at: now()) != nil {
            // 最終 PR の作成は claude を使わないので、待っている間も進める
            _ = await finalizeCompletedEpics(statuses: statuses)
            await publishLoopStatuses(statuses: statuses)
            return []
        }

        // ask への回答: 止まっているループを再開し、すべて回答済みなら needs-answer を外す。
        // 失敗しても ready-for-loop の判定は続ける
        do {
            try await handleAnswers(statuses: &statuses)
        } catch {
            log("回答の確認に失敗しました: \(error)")
        }

        // 異常終了したループ（タスクを残したまま止まった）を再開する。
        // 新しい Discussion の起動より先に行い、途中の epic に別の epic を被せない
        await resumeStalledLoops(statuses: &statuses)

        // 仮決め一覧: 最終 PR がマージされたら閉じ、マージ前に付いた指示ではループを再開する
        await handleDecisionLogs(statuses: &statuses)

        // 最終 PR への指示: マージ待ちの間に付いた指示ではループを再開する（仮決め一覧が無い epic でも直させる）
        await handleFinalPullRequestInstructions(statuses: &statuses)

        // 止まったループの epic が完了していたら、既定ブランチへの最終 PR（epic-final）を作る。
        // 新しい Discussion の起動（前の epic の作業ファイルを退避する）より先に行う
        let unfinalized = await finalizeCompletedEpics(statuses: statuses)

        // ready-for-loop の検索は失敗しうるので、ここまで（回答・異常終了・固まったループの再開と最終 PR）を先に済ませる
        let discussions = try await github.readyForLoopDiscussions(orgs: config.orgs)

        // 起動済みの Discussion: ループの開始を確かめたらラベルを外す
        let snapshots = await epicSnapshots()
        let handled = await advanceLaunchedDiscussions(discussions, statuses: statuses, snapshots: snapshots)
        // 準備の結果やることが無かった Discussion（ラベルを外した・外し直す）は、開始待ちとして書かない
        recordReadyDiscussions(discussions.filter { !handled.contains($0.nodeID) }, snapshots: snapshots)

        // 手動ループ（open な `manual-loop` の Discussion）があるリポジトリでも、自動ループは 1 つ起動する（Discussion #425）。
        // リポジトリごとに 1 つの制限は、制御用 worktree の state ファイル・途中の epic・同じポーリングの起動で守る
        let decisions = LaunchPlanner.decide(
            discussions,
            config: config,
            statuses: statuses,
            excluding: tracker.blockedDiscussionIDs.union(handled),
            epicsInProgress: Set(snapshots.filter(\.value.inProgress).keys).union(unfinalized),
            trust: trust
        )
        await carryOut(decisions, statuses: &statuses)

        // 新機能の依頼: claude に質問付きの Discussion を作らせる（1 回のポーリングで 1 件）
        do {
            try await handleIdeaRequests()
        } catch {
            log("依頼の確認に失敗しました: \(error)")
        }
        // 担当リポジトリの作成・削除の依頼（1 回のポーリングで 1 件）
        do {
            try await handleRepositoryRequests(statuses: statuses)
        } catch {
            log("リポジトリの作成・削除の依頼の確認に失敗しました: \(error)")
        }
        // 最終 PR のコンフリクトの解消と、ループの状態の書き出し（起動・再開を反映した後）
        await finishPoll(statuses: statuses)
        return decisions
    }

    /// 起動判定のとおりに起動し、起動しない理由をログに出す
    private func carryOut(_ decisions: [LaunchDecision], statuses: inout [String: LoopStatus]) async {
        for decision in decisions {
            switch decision {
            case let .launch(discussion, repository):
                if await launch(discussion, in: repository) {
                    statuses[repository.fullName.lowercased()] = LoopStatus(stateFileExists: false, processAlive: true)
                }

            case let .skip(discussion, reason):
                if let message = Self.describe(reason) {
                    log("\(Self.name(of: discussion)) は起動しません: \(message)")
                }
            }
        }
    }

    /// 担当リポジトリに「担当している」印（最終確認の時刻）を書く。アプリが「担当 PC なし」を判断するのに使う。
    /// 同じリポジトリには `OrchestratorHeartbeat.updateInterval` に 1 回まで
    private func updateHeartbeats() async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            if let last = lastHeartbeats[key], current.timeIntervalSince(last) < OrchestratorHeartbeat.updateInterval {
                continue
            }
            do {
                let description = OrchestratorHeartbeat.description(at: current, usageLimitedUntil: activeUsageLimit(at: current))
                try await github.updateHeartbeat(in: repository.fullName, description: description)
                lastHeartbeats[key] = current
            } catch {
                log("\(repository.fullName) に担当の印を書けませんでした（次のポーリングで再試行します）: \(error)")
            }
        }
    }

    private func handleAnswers(statuses: inout [String: LoopStatus]) async throws {
        var snapshots: [AnswerSnapshot] = []
        for subject in try await inbox.subjectsNeedingAnswer(orgs: config.orgs)
        where config.repository(named: subject.repository) != nil {
            // 1 件の失敗（権限不足など）で、ほかの Discussion / PR の再開とラベルの削除を止めない
            do {
                let threads = try await inbox.questionThreads(of: subject)
                snapshots.append(AnswerSnapshot(subject: subject, threads: threads, trustedAuthors: trust.authors(for: subject.repository)))
            } catch {
                log("\(subject.repository)#\(subject.number) の質問を取得できませんでした: \(error)")
            }
        }
        let epics = await epicSnapshots()
        let actions = watcher.update(
            snapshots: snapshots,
            statuses: statuses,
            // 回答待ちのタスクしか残っていない epic（最終 PR のマージ待ちも）も、回答を処理させるために再開する
            epicsInProgress: Set(epics.filter { $0.value.inProgress || $0.value.awaitingAnswer }.keys),
            automaticEpics: automaticEpicBranches(in: epics),
            manualLoopRepositories: manualLoopRepositories
        )
        for action in actions {
            switch action {
            case let .removeNeedsAnswer(subject):
                await handleFullyAnswered(subject, addsReadyLabel: true)

            case let .removeNeedsAnswerOfManualLoop(subject):
                await handleFullyAnswered(subject, addsReadyLabel: false)

            case let .resume(key):
                guard let repository = config.repository(named: key) else {
                    continue
                }
                if await resume(repository, branch: epics[key]?.branch) {
                    // 同じ周回の ready-for-loop の判定で、二重に起動しない
                    statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
                }

            case let .giveUp(key, attempts):
                log("\(key) のループの再開を \(attempts) 回確かめられませんでした。次の回答が付くまで再開しません（loopCommand を確認してください）")

            case let .noEpicInProgress(key):
                log("\(key) の ask に回答が付きましたが、途中の epic（回答待ちを含む未完了のタスク）が無いので、ループは再開しません")
            }
        }
    }

    /// 回答を受けてループを再開する。起動できたら `true`。`branch` は制御用 worktree の epic
    private func resume(_ repository: RepositoryConfig, branch: String?) async -> Bool {
        let key = repository.fullName.lowercased()
        // 回答待ちのタスクしか残っていなくても起動スクリプトが起動するよう、ask への回答による再開だと伝える
        let reason = [Self.resumeReasonVariable: Self.answerResumeReason]
        do {
            // 再開では Discussion を伴わないので `{discussion}` は空になる
            try await runtime.launch(
                config.loopCommand.render(for: repository),
                environment: loopEnvironment(for: repository).merging(reason) { _, new in new },
                for: repository
            )
        } catch {
            let entry = watcher.recordLaunchFailure(repositoryKey: key)
            log("\(repository.fullName) のループを再開できませんでした（\(entry.attempts)/\(ResumeWatcher.maxAttempts) 回目）: \(error)")
            return false
        }
        watcher.recordLaunch(repositoryKey: key)
        if let branch {
            // 最終 PR を作った後の epic でも、ループが再び完了したら「最終 PR に載せる内容」で本文を書き直す
            // （回答待ちの PR の扱いが変わるため）。最終 PR がまだ無ければ、作るときに外す
            let epicKey = "\(key) \(branch)"
            finalizedEpics.remove(epicKey)
            epicsToRefresh.insert(epicKey)
        }
        log("\(repository.fullName) の ask に回答が付いたので、ループを再開しました")
        return true
    }

    /// 回答を受けて再開を待っているリポジトリ（テスト用）
    var pendingResumes: [String: ResumeWatcher.Entry] {
        watcher.resumes
    }

    /// 追跡中の Discussion の状態（テスト用）
    var trackedEntries: [String: LaunchTracker.Entry] {
        tracker.entries
    }

    /// 起動できたら `true`
    private func launch(_ discussion: ReadyDiscussion, in repository: RepositoryConfig) async -> Bool {
        let key = repository.fullName.lowercased()
        do {
            try await runtime.launch(
                config.loopCommand.render(for: repository, discussionNumber: discussion.number),
                environment: loopEnvironment(for: repository),
                for: repository
            )
        } catch {
            let entry = tracker.recordLaunchFailure(of: discussion, repositoryKey: key)
            let next = entry.phase == .gaveUp ? "起動をやめます（ready-for-loop は残します）" : "次のポーリングで再試行します"
            log("\(Self.name(of: discussion)) のループを起動できませんでした（\(entry.attempts)/\(LaunchTracker.maxAttempts) 回目）: \(error)。\(next)")
            return false
        }
        tracker.recordLaunch(of: discussion, repositoryKey: key)
        log("\(Self.name(of: discussion)) のループを起動しました。開始を確かめてから ready-for-loop を外します")
        return true
    }

    func perform(_ action: LaunchTracker.Action) async {
        switch action {
        case let .removeLabel(discussion):
            do {
                try await github.removeReadyLabel(from: discussion)
                tracker.recordLabelRemoved(from: discussion)
                log("\(Self.name(of: discussion)) のループの開始を確かめ、ready-for-loop を外しました")
            } catch {
                // 追跡を続けるので、外せるまで二重に起動せず、次のポーリングで外し直す
                log("\(Self.name(of: discussion)) の ready-for-loop を外せませんでした（次のポーリングで再試行します）: \(error)")
            }

        case let .retry(discussion, attempts):
            log("\(Self.name(of: discussion)) のループの開始を確かめられないままプロセスが終わりました（\(attempts)/\(LaunchTracker.maxAttempts) 回目）。起動し直します")

        case let .giveUp(discussion, attempts):
            log("\(Self.name(of: discussion)) のループの開始を \(attempts) 回確かめられませんでした。起動をやめます（loopCommand を確認してください）")
        }
    }

    private static func name(of discussion: ReadyDiscussion) -> String {
        "\(discussion.repository)#\(discussion.number)"
    }

    /// ログに出す見送りの理由。毎回のポーリングで出るため、人の対応が要るものだけにする
    /// （別の PC の担当・ループの実行中・順番待ちは、待てば解消するので出さない）
    private static func describe(_ reason: LaunchDecision.SkipReason) -> String? {
        switch reason {
        case .notAssigned, .loopRunning, .waitingForAnotherDiscussion, .alreadyLaunched, .epicInProgress:
            nil

        case .untrustedAuthor:
            "Discussion の author が信用する author ではありません"

        case .manualLoop:
            "manual-loop（手で回す）が付いています。ループは手で始めてください"

        case .loopStateRemains:
            "制御用 worktree に .claude/ralph-loop.local.md が残っています"

        case .loopStatusUnknown:
            "制御用 worktree の .claude/ralph-loop.local.md の有無を確かめられません（アクセス権を確認してください）"
        }
    }
}
