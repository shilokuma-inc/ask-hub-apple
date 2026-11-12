import AskHubProtocol
import Foundation

/// 送るときに要る、画面の id からプロトコルの対象への引き当て。取り直すたびに作り直す
struct StateIndex {
    struct EpicEntry {
        var repo: RepositoryFullName
        var id: ULID
        var goalVersion: Int?
        var readinessVersion: Int?
        /// 「対処が要ります」に出した、人の対応を待っているジョブ（やり直す・やめるの対象）と、そこに出した操作
        var blockedJob: JobTarget?
        var blockerActions: Set<Blocker.Action> = []
        /// やめていないか・取り下げられるか（開始する前で、やめていない）。どちらも処理を待つ意図を当てた後の状態で決める
        var isActive = true
        var canAbandon = false
        /// 最終 PR（出した後だけ）
        var final: FinalEntry?
        /// 終えたことを送れる人がする作業（ゴールの確認の待ちと実装の間の、終えていないもの）と、その渡すものの種類
        var humanTasks: [HumanTask.ID: HandoverKind] = [:]
        /// 開始した後（実装・最終 PR の段取り・人の確認の待ち）か。一時停止・再開・引き継ぎは、このときだけ送れる
        var isStarted = false
        /// epic の Mac でジョブが動いているか（一時停止していない epic は、終わるまで引き継げない）
        var isBusyOnMac = false
        /// epic の Mac（同じ Mac への引き継ぎは送らない）。処理を待つ引き継ぎを当てた後のもの
        var mac: MacName?
        /// 一時停止・再開・引き継ぎができるか。処理を待つ意図を当てた後の状態で決める
        var canPause = false
        var canResume = false
        var canHandOver = false
    }

    /// 最終 PR への意図（判断のカードへの答え・マージの承認・指示）の対象
    struct FinalEntry {
        var pullRequest: Int
        /// いまの head（意図の対象の版）。分からなければ nil
        var head: String?
        /// 答えられる判断のカード（見えると仕分けた仮決め）の id。仕分ける前の仮決めはカードに出すが、司令塔が答えを受け付けない
        var decisionIDs: Set<String>
        /// 答えの無いカードの id（まとめて OK の対象）。処理を待つ答えを当てた後のもの
        var unansweredDecisionIDs: [String]
        /// 司令塔がマージの承認を受け付けるか（`FinalMergeRule.canApprove`。判断の一覧を読めなかったときは false）。処理を待つ答えを当てた後のもの
        var canApprove: Bool
        /// 人が確かめる段階か。処理を待つ承認・指示を当てた後の状態で決める
        var isReviewable: Bool
    }

    /// 配信した版への意図（リリース文の公開）の対象
    struct ReleaseEntry {
        var target: ReleaseTarget
        /// 公開を送れるか（下書きがあり、まだ公開していない）。処理を待つ公開を当てた後のもの
        var canPublish: Bool
    }

    struct QuestionEntry {
        /// プロトコルの質問の id（画面では大文字にして出す）
        var id: String
        var version: Int
    }

    var epics: [Epic.ID: EpicEntry] = [:]
    var questions: [Epic.ID: [Question.ID: QuestionEntry]] = [:]
    var repositories: [TargetRepository.ID: RepositoryFullName] = [:]
    var releases: [Release.ID: ReleaseEntry] = [:]
}

/// 状態リポジトリのファイル（`StateDocuments`）を、画面用のモデル（`ClientSnapshot`）に変える。
///
/// プロトコルの型から画面の型への変換はここにだけ書く。この端末が送って司令塔がまだ処理していない意図は、
/// 送った結果として先に画面に出す（取り直したときに、答えた札が戻ってこないように）
struct StateSnapshotBuilder {
    let documents: StateDocuments
    let now: Date
    /// 読んだ中にまだ無い、この端末の意図（新しい順）。送っている途中・取り消しの猶予の間・送り終えて読み直す前のもの。
    /// 処理を待つ意図と同じく送った結果として先に出すが、送った意図の一覧（`ClientSnapshot.sentIntents`）には入れない
    var unread: [IntentEnvelope] = []
    /// 司令塔が受け付けたのを読んだばかりで、状態への反映をまだ読めていないかもしれない意図。処理を待つ意図と同じく当てる
    /// （受け付けの記録は状態を書き換えた後に書くが、並べて読む 1 回の読み込みでは、記録が新しく状態が古いことがある。
    /// 当てる処理は対象が変わっていれば何もしないので、反映された状態に当てても変わらない）
    var justAccepted: Set<ULID> = []

    /// 生きている印がこれより古い Mac は、オフラインとして出す（`docs/renewal/flows.md` の開始の確かめ）
    static let onlineWindow: TimeInterval = 30 * 60
    /// 署名した意図の有効期間。これより古い処理待ちの意図は、司令塔が期限切れとして断る
    static let intentLifetime: TimeInterval = 7 * 24 * 60 * 60

    func build() -> (snapshot: ClientSnapshot, index: StateIndex) {
        var index = StateIndex()
        var epics = documents.epics.map { epic($0, index: &index) }
        var repositories = documents.repositories.map { repository($0, epics: epics, index: &index) }
        let overlaid = intentsToOverlay()
        // 古い順に当てる（同じ質問に答え直したときは、新しい回答が残る）
        for envelope in overlaid.reversed() {
            apply(envelope, to: &epics, repositories: &repositories, index: &index)
        }
        applyBlockers(to: &epics, overlaid: overlaid, index: &index)
        for epic in epics {
            index.epics[epic.id]?.isActive = epic.isActive
            if !epic.isActive {
                // 取り下げを送った epic の作業は、もう終えられない
                index.epics[epic.id]?.humanTasks = [:]
            }
            index.epics[epic.id]?.final?.isReviewable = epic.isActive && epic.finalReview?.state == .reviewable
            // 開始した後の取り下げ（作業のブランチの片付けなど）は段階 3 で送る
            index.epics[epic.id]?.canAbandon = epic.isActive && epic.stage < .implementing
            applyPauseControls(of: epic, to: &index)
        }
        applyRejections(to: &epics)
        let releases = releases(index: &index, overlaid: overlaid)
        let snapshot = ClientSnapshot(
            repositories: repositories.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending },
            candidateRepositories: [],
            epics: epics.sorted { $0.updatedAt > $1.updatedAt },
            macs: macs(),
            fetchedAt: now,
            sourceFailures: documents.failures,
            sentIntents: documents.sentIntents.map(sentStatus),
            commanderSeenAt: documents.commander?.seenAt.date,
            releases: releases
        )
        return (snapshot, index)
    }

    // MARK: リポジトリ

    private func repository(_ file: RepositoryFile, epics: [Epic], index: inout StateIndex) -> TargetRepository {
        var repository = Self.repository(file.repo)
        index.repositories[repository.id] = file.repo
        repository.icon = Self.appIcon(of: file)
        repository.lastMacID = epics.filter { $0.repositoryID == repository.id && $0.macID != nil }
            .max { $0.updatedAt < $1.updatedAt }?.macID
        return repository
    }

    /// 司令塔が置いたアプリのアイコン。まだ無ければ頭文字
    static func appIcon(of file: RepositoryFile) -> RepositoryIcon {
        guard let icon = file.icon else { return .monogram }
        return .stored(path: StatePath.appIcon(file.repo), version: icon.image)
    }

    static func repository(_ repo: RepositoryFullName) -> TargetRepository {
        TargetRepository(
            owner: repo.owner, ownerAvatar: ownerAvatar(of: repo), name: repo.name, appName: repo.name, icon: .monogram, lastMacID: nil
        )
    }

    /// 持ち主の GitHub のアバター（`https://github.com/<owner>.png` は画像へ転送する）。public の画像なので、トークンを付けずに読む。
    /// 持ち主の名前は `RepositoryFullName` が英数字とハイフンだけに限っているので、そのまま URL に入れられる
    static func ownerAvatar(of repo: RepositoryFullName) -> RepositoryIcon {
        URL(string: "https://github.com/\(repo.owner).png?size=\(ownerAvatarPixels)").map { .image($0) } ?? .monogram
    }

    /// アバターを取り寄せる大きさ（画素）。見出しに出す 20pt ほどを 3 倍の画面でも粗くなく描ける
    static let ownerAvatarPixels = 96

    // MARK: Mac

    private func macs() -> [Mac] {
        var macs = documents.macs.map(mac)
        if let commander = documents.commander, !macs.contains(where: { $0.id == commander.mac.rawValue }) {
            macs.append(commanderOnly(commander))
        }
        return macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func mac(_ file: MacFile) -> Mac {
        let checks = Self.selfChecks(file.selfCheck)
        let tokens = Self.tokens(file.selfCheck)
        let incompatibility = incompatibility(of: file)
        return Mac(
            id: file.mac.rawValue,
            name: file.mac.rawValue,
            model: "",
            role: documents.commander?.mac == file.mac ? .commandCenter : .worker,
            residency: Self.residency(file.kind),
            connection: connection(seenAt: file.seenAt.date),
            freeBytes: Int64(file.diskFreeGB) * 1_000_000_000,
            totalBytes: 0,
            load: 0,
            version: file.versions.worker,
            jobs: runningJobs(on: file.mac),
            refusalReason: incompatibility == nil ? refusalReason(tokens: tokens, checks: checks) : Self.incompatibleReason,
            selfChecks: checks,
            tokens: tokens,
            claudeVersion: file.versions.claude,
            commanderClaudeVersion: commanderClaudeVersion(differingFrom: file.versions.claude),
            xcodeVersion: file.versions.xcode,
            cleanupCandidates: [],
            loadAverage: file.load,
            githubQuota: Self.quota(file.selfCheck),
            compatibility: file.versions.compatibility,
            commanderVersion: commanderVersion(differingFrom: file.versions.worker),
            incompatibility: incompatibility
        )
    }

    /// 司令塔だけが動いていて、ワーカーの印が無い Mac。ループは受けない
    private func commanderOnly(_ file: CommanderFile) -> Mac {
        let tokens = Self.tokens(file.selfCheck)
        return Mac(
            id: file.mac.rawValue,
            name: file.mac.rawValue,
            model: "",
            role: .commandCenter,
            residency: .always,
            connection: connection(seenAt: file.seenAt.date),
            freeBytes: 0,
            totalBytes: 0,
            load: 0,
            version: file.versions.commander,
            jobs: [],
            refusalReason: refusalReason(tokens: tokens, checks: []) ?? "ワーカーが動いていません",
            selfChecks: Self.selfChecks(file.selfCheck),
            tokens: tokens,
            claudeVersion: file.versions.claude,
            cleanupCandidates: [],
            githubQuota: Self.quota(file.selfCheck),
            compatibility: file.versions.compatibility
        )
    }

    /// 互換の番号が司令塔と合わないワーカーの、新しいループを受けない理由
    static let incompatibleReason = "司令塔と互換の番号が合わず、新しいジョブを引き受けていません"

    /// 司令塔と互換の番号が合わない Mac。ワーカーが引き受けない理由を印に書いていれば、それも添える。
    /// 常時オンの Mac のワーカーは司令塔と同じ実行ファイルなので比べない。番号を書かない（前の版の）ものとは、ワーカーが理由を書いていなければ比べない
    private func incompatibility(of file: MacFile) -> Mac.Incompatibility? {
        guard documents.commander?.mac != file.mac else {
            return nil
        }
        let commander = documents.commander?.versions.compatibility
        let refusal = file.refusal.flatMap { $0.reason == .incompatible ? $0.message : nil }
        let differs = commander != nil && file.versions.compatibility != nil && commander != file.versions.compatibility
        guard differs || refusal != nil else {
            return nil
        }
        return Mac.Incompatibility(commanderCompatibility: commander, message: refusal)
    }

    /// 版が司令塔と違うときの、司令塔の版（分からなければ比べない）
    private func commanderVersion(differingFrom version: String) -> String? {
        guard let commander = documents.commander?.versions.commander, commander != version else {
            return nil
        }
        return commander
    }

    /// 自己診断の、持ち主ごとのトークンで読んだ残りのうち一番少ないもの
    private static func quota(_ check: SelfCheck) -> GitHubQuota? {
        check.githubRateLimit.map { limit in
            GitHubQuota(limit: limit.limit, remaining: limit.remaining, resetAt: limit.resetAt.date, checkedAt: check.checkedAt.date)
        }
    }

    /// Claude Code の版が司令塔と違うときの、司令塔の版（どちらかが分からなければ比べない）
    private func commanderClaudeVersion(differingFrom version: String?) -> String? {
        guard let version, let commander = documents.commander?.versions.claude, commander != version else {
            return nil
        }
        return commander
    }

    /// 新しいループを受けない理由。止まっているトークンを先に出す
    private func refusalReason(tokens: [MacToken], checks: [Mac.SelfCheck]) -> String? {
        if let token = tokens.first(where: { $0.isStopped(now: now) }) {
            return token.status(now: now) == .stopped(.expired) ? "\(token.name)の期限が切れて止まっています" : "\(token.name)が使えず止まっています"
        }
        return checks.allSatisfy(\.isOK) ? nil : "自己診断で問題が見つかっています"
    }

    private func connection(seenAt: Date) -> Mac.Connection {
        now.timeIntervalSince(seenAt) < Self.onlineWindow ? .online(lastSeen: seenAt) : .offline(since: seenAt)
    }

    private static func residency(_ kind: MacKind) -> Mac.Residency {
        switch kind {
        case .alwaysOn: .always
        case .resident: .whileOpen
        case .manual: .manual
        }
    }

    /// トークンは期限と合わせて `tokens` に出すので、ここには Keychain だけを出す
    private static func selfChecks(_ check: SelfCheck) -> [Mac.SelfCheck] {
        [Mac.SelfCheck(name: "Keychain", isOK: check.keychain == .ok, detail: label(check.keychain))]
    }

    /// 期限のあるトークン。持ち主ごとの内訳を書かない Mac（前の版）は、まとめた様子を 1 つにして出す
    private static func tokens(_ check: SelfCheck) -> [MacToken] {
        let github = check.githubTokens?.map { token in
            MacToken(kind: .github(owner: token.owner), state: state(token.state), expiresAt: token.expiresAt?.date)
        } ?? [MacToken(kind: .github(owner: nil), state: state(check.githubToken), expiresAt: check.githubTokenExpiresAt?.date)]
        return github + [MacToken(kind: .claude, state: state(check.claudeToken), expiresAt: check.claudeTokenExpiresAt?.date)]
    }

    private static func state(_ state: SelfCheck.State) -> MacToken.State {
        switch state {
        case .ok: .ok
        case .missing: .missing
        case .invalid: .invalid
        case .expired: .expired
        }
    }

    private static func label(_ state: SelfCheck.State) -> String {
        switch state {
        case .ok: "問題なし"
        case .missing: "見つかりません"
        case .invalid: "使えません"
        case .expired: "期限が切れています"
        }
    }
}
