import AskHubProtocol
import Foundation

/// 送るときに要る、画面の id からプロトコルの対象への引き当て。取り直すたびに作り直す
struct StateIndex {
    struct EpicEntry {
        var repo: RepositoryFullName
        var id: ULID
        var goalVersion: Int?
        var readinessVersion: Int?
        /// 「対処が要ります」に出した、人の対応を待っているジョブ（やり直す・やめるの対象）
        var blockedJob: JobTarget?
        /// 取り下げられるか（開始する前で、やめていない。処理を待つ意図を当てた後の段階で決める）
        var canAbandon = false
    }

    struct QuestionEntry {
        /// プロトコルの質問の id（画面では大文字にして出す）
        var id: String
        var version: Int
    }

    var epics: [Epic.ID: EpicEntry] = [:]
    var questions: [Epic.ID: [Question.ID: QuestionEntry]] = [:]
    var repositories: [TargetRepository.ID: RepositoryFullName] = [:]
}

/// 状態リポジトリのファイル（`StateDocuments`）を、画面用のモデル（`ClientSnapshot`）に変える。
///
/// プロトコルの型から画面の型への変換はここにだけ書く。この端末が送って司令塔がまだ処理していない意図は、
/// 送った結果として先に画面に出す（取り直したときに、答えた札が戻ってこないように）
struct StateSnapshotBuilder {
    let documents: StateDocuments
    let now: Date

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
        // 開始した後の取り下げ（作業のブランチの片付けなど）は段階 3 で送る
        for epic in epics where epic.isActive && epic.stage < .implementing {
            index.epics[epic.id]?.canAbandon = true
        }
        applyRejections(to: &epics)
        let snapshot = ClientSnapshot(
            repositories: repositories.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending },
            candidateRepositories: [],
            epics: epics.sorted { $0.updatedAt > $1.updatedAt },
            macs: macs(),
            fetchedAt: now,
            sourceFailures: documents.failures,
            sentIntents: documents.sentIntents.map(sentStatus)
        )
        return (snapshot, index)
    }

    // MARK: リポジトリ

    private func repository(_ file: RepositoryFile, epics: [Epic], index: inout StateIndex) -> TargetRepository {
        let repository = Self.repository(file.repo)
        index.repositories[repository.id] = file.repo
        var lastMac = repository
        lastMac.lastMacID = epics.filter { $0.repositoryID == repository.id && $0.macID != nil }.max { $0.updatedAt < $1.updatedAt }?.macID
        return lastMac
    }

    static func repository(_ repo: RepositoryFullName) -> TargetRepository {
        TargetRepository(owner: repo.owner, name: repo.name, appName: repo.name, icon: .monogram, lastMacID: nil)
    }

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
        return Mac(
            id: file.mac.rawValue,
            name: file.mac.rawValue,
            model: [file.versions.xcode.map { "Xcode \($0)" }, file.versions.claude.map { "Claude \($0)" }]
                .compactMap(\.self)
                .joined(separator: " · "),
            role: documents.commander?.mac == file.mac ? .commandCenter : .worker,
            residency: Self.residency(file.kind),
            connection: connection(seenAt: file.seenAt.date),
            freeBytes: Int64(file.diskFreeGB) * 1_000_000_000,
            totalBytes: 0,
            load: 0,
            version: file.versions.worker,
            versionMatches: true,
            jobs: [],
            refusalReason: checks.allSatisfy(\.isOK) ? nil : "自己診断で問題が見つかっています",
            selfChecks: checks,
            cleanupCandidates: [],
            loadAverage: file.load
        )
    }

    /// 司令塔だけが動いていて、ワーカーの印が無い Mac。ループは受けない
    private func commanderOnly(_ file: CommanderFile) -> Mac {
        Mac(
            id: file.mac.rawValue,
            name: file.mac.rawValue,
            model: file.versions.claude.map { "Claude \($0)" } ?? "",
            role: .commandCenter,
            residency: .always,
            connection: connection(seenAt: file.seenAt.date),
            freeBytes: 0,
            totalBytes: 0,
            load: 0,
            version: file.versions.commander,
            versionMatches: true,
            jobs: [],
            refusalReason: "ワーカーが動いていません",
            selfChecks: Self.selfChecks(file.selfCheck),
            cleanupCandidates: []
        )
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

    private static func selfChecks(_ check: SelfCheck) -> [Mac.SelfCheck] {
        [("Keychain", check.keychain), ("GitHub のトークン", check.githubToken), ("Claude のトークン", check.claudeToken)].map { name, state in
            Mac.SelfCheck(name: name, isOK: state == .ok, detail: label(state))
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
