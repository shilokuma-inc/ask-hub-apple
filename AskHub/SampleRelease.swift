import AskHubKit
import Foundation

extension ReleaseRequestModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続せず、起動しても送ったことにするだけ。
    /// 起動した run は `runDuration` 秒で終わったことにする（リリース準備 → アップロード → 下書き、最新情報の確定 → 確定済み）
    static func sample(runDuration: TimeInterval = SampleReleaseStore.defaultRunDuration) -> ReleaseRequestModel {
        // 読み取りとワークフローで、起動したことを共有する
        let store = SampleReleaseStore(runDuration: runDuration)
        return ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeReader: { _ in SampleReleaseReader(store: store) },
            makeWorkflow: { _, file in SampleReleaseWorkflow(file: file, store: store) },
            dispatchRefreshDelay: .seconds(1)
        )
    }
}

/// デモモードの 1 つのリポジトリのリリースの状態（`SampleIdeaRequester` のリポジトリに合わせる）
nonisolated struct SampleReleaseScenario: Sendable {
    enum Run: Sendable {
        case running
        case succeeded
    }

    enum Notes: Sendable {
        case missing
        case draft(WhatsNewDraft)
        /// このリリースのバージョンで確定した本文
        case confirmed(String)
    }

    /// `develop` の `MARKETING_VERSION`
    var marketingVersion: String
    /// リリース済みのバージョン（release ブランチとタグがある）
    var released: [String]
    /// 準備中のリリース（タグの無い release ブランチ）
    var unreleased: ReleaseVersion?
    /// 準備中のリリースの、最初から出す run（ワークフローのファイル → 状態）
    var runs: [String: Run] = [:]
    var notes = Notes.missing
    /// 前のリリースで確定した最新情報（`AppStore/metadata/ja.json` に残っているもの）
    var previousWhatsNew: ConfirmedWhatsNew?

    /// リポジトリ → 状態。ここに無いリポジトリにはリリースのワークフローが無い
    /// - ask-hub-apple: `MARKETING_VERSION` 1.2.0・リリース済みの v1.0.0 / v1.1.0（既定値は 1.3.0）。始めると準備中になる
    /// - claude-plugins: 準備中（release/0.4.0 のリリース準備の run が実行中）
    /// - notti-ios: 下書きあり（release/2.1.0。準備とアップロードが終わった）。確定すると確定済みになる
    /// - beat-tap-ios: `MARKETING_VERSION` 1.0.0・タグなし（初回のリリース）
    /// - web-tools: 最新情報を確定済みで、配信待ち（release/1.5.0）
    /// - sandbox: 完了（release/0.9.0 のリリース後作業の run が成功した）
    static let all: [String: Self] = [
        "shilokuma-inc/ask-hub-apple": Self(marketingVersion: "1.2.0", released: ["1.0.0", "1.1.0"]),
        SampleReleaseReader.preparingRepository: Self(
            marketingVersion: "0.4.0",
            released: ["0.3.0"],
            unreleased: ReleaseVersion("0.4.0"),
            runs: [ReleaseWorkflow.prepare.file: .running]
        ),
        SampleReleaseReader.draftRepository: Self(
            marketingVersion: "2.1.0",
            released: ["2.0.0"],
            unreleased: SampleReleaseReader.draftVersion,
            runs: [ReleaseWorkflow.prepare.file: .succeeded, ReleaseProgress.uploadFile: .succeeded],
            notes: .draft(SampleReleaseReader.draft),
            previousWhatsNew: ConfirmedWhatsNew(version: "2.0.0", text: "・ウィジェットを追加しました")
        ),
        "shilokuma-inc/beat-tap-ios": Self(marketingVersion: "1.0.0", released: []),
        SampleReleaseReader.waitingRepository: Self(
            marketingVersion: "1.5.0",
            released: ["1.4.0"],
            unreleased: ReleaseVersion("1.5.0"),
            runs: [
                ReleaseWorkflow.prepare.file: .succeeded,
                ReleaseProgress.uploadFile: .succeeded,
                ReleaseWorkflow.notes.file: .succeeded
            ],
            notes: .confirmed("・画像の変換を速くしました\n・ダークモードの色を直しました")
        ),
        SampleReleaseReader.finishedRepository: Self(
            marketingVersion: "0.9.0",
            released: ["0.8.0"],
            unreleased: ReleaseVersion("0.9.0"),
            runs: [
                ReleaseWorkflow.prepare.file: .succeeded,
                ReleaseProgress.uploadFile: .succeeded,
                ReleaseWorkflow.notes.file: .succeeded,
                ReleaseWorkflow.finish.file: .succeeded
            ],
            notes: .confirmed("・はじめての公開版です")
        )
    ]
}

/// デモモードで起動したこと（送ったことにしたもの）を覚えておき、読み取りに返す状態を作る。
/// 起動した run は `runDuration` 秒たつと成功で終わる。リリース準備が終わるとアップロードが始まり、下書きができる。
/// 最新情報の確定が終わると、送った本文で確定済みになる
actor SampleReleaseStore {
    nonisolated static let defaultRunDuration: TimeInterval = 3

    private struct Dispatch {
        var id: Int
        var date: Date
        var ref: String
        var inputs: [String: String]

        var version: ReleaseVersion? {
            ReleaseVersion(inputs["version"] ?? "")
        }
    }

    private let runDuration: TimeInterval
    private let now: @Sendable () -> Date
    /// 最初から出す run の開始時刻
    private let createdAt: Date
    /// ワークフローのファイル → リポジトリ → 直近の起動
    private var dispatches: [String: [String: Dispatch]] = [:]
    /// 本物と同じく、起動するたびに新しい（大きい）id の run にする。最初から出す run は id 1〜
    private var lastRunID = 100

    init(runDuration: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runDuration = runDuration
        self.now = now
        createdAt = now()
    }

    func dispatch(file: String, repository: String, ref: String, inputs: [String: String]) {
        lastRunID += 10
        dispatches[file, default: [:]][repository] = Dispatch(id: lastRunID, date: now(), ref: ref, inputs: inputs)
    }

    // MARK: - 読み取り

    func refs(repository: String) -> ReleaseRefs {
        guard let scenario = SampleReleaseScenario.all[repository] else {
            return ReleaseRefs(branches: [], tags: [])
        }
        let released = scenario.released.compactMap { ReleaseVersion($0) }
        let unreleased = [scenario.unreleased, prepareDispatch(repository)?.version].compactMap(\.self)
        return ReleaseRefs(
            branches: (released + unreleased).map { Self.ref($0.branchName, version: ReleaseVersion(branch: $0.branchName)) },
            tags: released.map { Self.ref($0.tagName, version: ReleaseVersion(tag: $0.tagName)) }
        )
    }

    func draft(repository: String, version: ReleaseVersion) -> WhatsNewDraft? {
        if case .draft(let draft) = notes(repository: repository, version: version).status {
            return draft
        }
        return nil
    }

    func notes(repository: String, version: ReleaseVersion) -> ReleaseNotes {
        let scenario = SampleReleaseScenario.all[repository]
        var whatsNew = scenario?.previousWhatsNew.map { ["ja": $0] } ?? [:]
        let notes = { (status: ReleaseNotes.Status) in
            ReleaseNotes(version: version, status: status, languages: ["ja"], whatsNew: whatsNew)
        }
        // 最新情報の確定が終わったら、送った本文で確定済みにする（下書きは消える）
        if let dispatch = dispatches[ReleaseWorkflow.notes.file]?[repository], dispatch.version == version {
            if isFinished(dispatch.date), let text = Self.sentText(dispatch.inputs) {
                whatsNew["ja"] = ConfirmedWhatsNew(version: version.description, text: text)
                return notes(.confirmed)
            }
        }
        // デモで始めたリリース準備は、終わると下書きができる
        if let dispatch = prepareDispatch(repository), dispatch.version == version {
            return notes(isFinished(dispatch.date) ? .draft(Self.generatedDraft(repository: repository, version: version)) : .missing)
        }
        guard let scenario, scenario.unreleased == version else {
            return notes(.missing)
        }
        switch scenario.notes {
        case .missing:
            return notes(.missing)

        case .draft(let draft):
            return notes(.draft(draft))

        case .confirmed(let text):
            whatsNew["ja"] = ConfirmedWhatsNew(version: version.description, text: text)
            return notes(.confirmed)
        }
    }

    /// ワークフローの run（新しい順）
    func runs(file: String, repository: String, title: String) -> [WorkflowRun] {
        if file == ReleaseProgress.uploadFile, let dispatch = prepareDispatch(repository), let version = dispatch.version {
            // リリース準備が終わったら、release ブランチでアップロードが始まる
            let start = dispatch.date.addingTimeInterval(runDuration)
            guard now() >= start else {
                return []
            }
            return [run(id: dispatch.id + 1, repository: repository, ref: version.branchName, start: start, title: "\(title) \(version)")]
        }
        if let dispatch = dispatches[file]?[repository] {
            let version = dispatch.version?.description ?? ""
            return [run(id: dispatch.id, repository: repository, ref: dispatch.ref, start: dispatch.date, title: "\(title) \(version)")]
        }
        guard let scenario = SampleReleaseScenario.all[repository], let version = scenario.unreleased,
              let state = scenario.runs[file] else {
            return []
        }
        // リリース準備は develop で、ほかは release ブランチで起動したことにする
        let ref = file == ReleaseWorkflow.prepare.file ? GitHubReleaseReader.developBranch : version.branchName
        let index = [ReleaseWorkflow.prepare.file, ReleaseProgress.uploadFile, ReleaseWorkflow.notes.file, ReleaseWorkflow.finish.file]
            .firstIndex(of: file) ?? 4
        return [
            WorkflowRun(
                id: index + 1,
                repository: repository,
                branch: ref,
                headSHA: "2222222",
                status: state == .running ? .inProgress : .completed,
                conclusion: state == .running ? nil : .success,
                event: "workflow_dispatch",
                startedAt: createdAt.addingTimeInterval(TimeInterval(index - 10) * 600),
                url: URL(string: "https://github.com/\(repository)/actions")!,
                displayTitle: "\(title) \(version)"
            )
        ]
    }

    private func prepareDispatch(_ repository: String) -> Dispatch? {
        dispatches[ReleaseWorkflow.prepare.file]?[repository]
    }

    private func isFinished(_ start: Date) -> Bool {
        now() >= start.addingTimeInterval(runDuration)
    }

    /// `start` に始まり、`runDuration` 秒たつと成功で終わる run
    private func run(id: Int, repository: String, ref: String, start: Date, title: String) -> WorkflowRun {
        let finished = isFinished(start)
        return WorkflowRun(
            id: id,
            repository: repository,
            branch: ref,
            headSHA: "0000000",
            status: finished ? .completed : .inProgress,
            conclusion: finished ? .success : nil,
            event: "workflow_dispatch",
            startedAt: start,
            url: URL(string: "https://github.com/\(repository)/actions")!,
            displayTitle: title
        )
    }

    /// 最新情報の確定で送った日本語の本文（`whats_new` は言語コード → 本文の JSON）
    private static func sentText(_ inputs: [String: String]) -> String? {
        guard let data = inputs["whats_new"]?.data(using: .utf8),
              let whatsNew = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return whatsNew["ja"]
    }

    /// デモで始めたリリース準備が作る下書き
    private static func generatedDraft(repository: String, version: ReleaseVersion) -> WhatsNewDraft {
        WhatsNewDraft(
            version: version.description,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            base: WhatsNewDraft.Commit(name: "v1.1.0", sha: "3333333"),
            head: WhatsNewDraft.Commit(name: "origin/develop", sha: "4444444"),
            initial: false,
            whatsNew: ["ja": "・受信箱を種類と並び順で絞り込めるようにしました\n・アプリからリリースの準備を始められるようにしました"],
            omitted: 0,
            pullRequests: [
                SampleReleaseReader.pullRequest(repository, 51, "受信箱を種類と並び順で絞り込む", type: "FEAT", included: true),
                SampleReleaseReader.pullRequest(repository, 52, "「新しい依頼」に「リリース準備」を足す", type: "FEAT", included: true),
                SampleReleaseReader.pullRequest(repository, 53, "リリースの手順を docs に書く", type: "DOCS", included: false)
            ],
            messages: ["v1.1.0 から develop に入った PR 3 件から作りました（CI・ドキュメントだけの PR は載せていません）"]
        )
    }

    private static func ref(_ name: String, version: ReleaseVersion?) -> ReleaseRef {
        ReleaseRef(name: name, sha: "0000000", version: version)
    }
}

/// デモモード・Preview・UI テスト用のリリースの読み取り（状態は `SampleReleaseScenario` と、デモで起動したもの）
nonisolated struct SampleReleaseReader: ReleaseReading {
    let store: SampleReleaseStore

    func refs(repository: String) async throws -> ReleaseRefs {
        await store.refs(repository: repository)
    }

    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
        guard let raw = SampleReleaseScenario.all[repository]?.marketingVersion else {
            throw ReleaseReadError.fileNotFound(path: GitHubReleaseReader.xcconfigPath, ref: ref)
        }
        return MarketingVersion(raw: raw)
    }

    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        await store.draft(repository: repository, version: version)
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        await store.notes(repository: repository, version: version)
    }

    /// 準備中（リリース準備の run が実行中）のリリース
    static let preparingRepository = "shilokuma-inc/claude-plugins"
    /// 下書きのある準備中のリリース
    static let draftRepository = "shilokuma-inc/notti-ios"
    static let draftVersion = ReleaseVersion(major: 2, minor: 1, patch: 0)
    /// 最新情報を確定済みで、配信待ちのリリース
    static let waitingRepository = "shilokuma-labs/web-tools"
    /// リリース後作業が終わったリリース
    static let finishedRepository = "shilokuma-labs/sandbox"

    static let draft = WhatsNewDraft(
        version: "2.1.0",
        generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
        base: WhatsNewDraft.Commit(name: "v2.0.0", sha: "1111111"),
        head: WhatsNewDraft.Commit(name: "origin/develop", sha: "2222222"),
        initial: false,
        whatsNew: ["ja": "・通知の時刻を曜日ごとに選べるようにしました\n・一覧のスクロール位置がリセットされる不具合を修正しました"],
        omitted: 0,
        pullRequests: [
            pullRequest(draftRepository, 41, "通知の時刻を曜日ごとに選べるようにする", type: "FEAT", included: true),
            pullRequest(draftRepository, 43, "一覧のスクロール位置がリセットされる不具合を修正", type: "FIX", included: true),
            pullRequest(draftRepository, 44, "CI の Xcode を 26.6 にする", type: "CI", included: false)
        ],
        messages: ["v2.0.0 から develop に入った PR 3 件から作りました（CI・ドキュメントだけの PR は載せていません）"]
    )

    static func pullRequest(
        _ repository: String,
        _ number: Int,
        _ title: String,
        type: String,
        included: Bool
    ) -> WhatsNewDraft.PullRequest {
        WhatsNewDraft.PullRequest(
            number: number,
            title: title,
            type: type,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)"),
            mergedAt: Date(timeIntervalSince1970: 1_789_000_000 + TimeInterval(number) * 3600),
            epic: nil,
            included: included
        )
    }
}

/// デモモード・Preview・UI テスト用のリリースのワークフロー（`release-prepare.yml`・`upload.yml`・`release-notes.yml`・`release-finish.yml`）。
/// 起動したことにして GitHub には送らず、`SampleReleaseStore` に覚えさせる
nonisolated struct SampleReleaseWorkflow: WorkflowProviding {
    let file: String
    let store: SampleReleaseStore

    func availability(repository: String) async throws -> WorkflowAvailability {
        SampleReleaseScenario.all[repository] == nil ? .notFound : .active
    }

    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        guard SampleReleaseScenario.all[repository] != nil else {
            return .unsupported
        }
        let runs = try await recentRuns(repository: repository, branch: branch, event: nil, limit: 1)
        return runs.first.map(LatestWorkflowRun.run) ?? .noRuns
    }

    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
        let runs = await store.runs(file: file, repository: repository, title: title)
        return Array(runs.filter { branch == nil || $0.branch == branch }.prefix(limit))
    }

    func dispatch(repository: String, ref: String, inputs: [String: String]) async throws {
        await store.dispatch(file: file, repository: repository, ref: ref, inputs: inputs)
    }

    private var title: String {
        ReleaseWorkflow(rawValue: file)?.actionName ?? "Upload"
    }
}
