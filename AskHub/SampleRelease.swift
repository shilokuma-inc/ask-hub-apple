import AskHubKit
import Foundation

extension ReleaseRequestModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続せず、起動しても送ったことにするだけ
    static func sample() -> ReleaseRequestModel {
        // 起動したことを覚えておくため、ワークフローごとに 1 つずつ作って使い回す
        let workflows = Dictionary(
            uniqueKeysWithValues: SampleReleaseWorkflow.files.map { ($0, SampleReleaseWorkflow(file: $0)) }
        )
        return ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeReader: { _ in SampleReleaseReader() },
            makeWorkflow: { _, file in workflows[file] ?? SampleReleaseWorkflow(file: file) },
            dispatchRefreshDelay: .seconds(1)
        )
    }
}

/// デモモード・Preview・UI テスト用のリリースの状態（`SampleIdeaRequester` のリポジトリに合わせる）。
/// - ask-hub-apple: `MARKETING_VERSION` 1.2.0・リリース済みのタグ v1.0.0 / v1.1.0（既定値は 1.3.0）
/// - notti-ios: タグの無い release/2.1.0 がある（準備中のリリースがあるので始められない）。準備とアップロードが終わり、最新情報の下書きがある
/// - beat-tap-ios: `MARKETING_VERSION` 1.0.0・タグなし（初回のリリース）
/// - ほか: リリースのワークフローが無い
struct SampleReleaseReader: ReleaseReading {
    static let marketingVersions = [
        "shilokuma-inc/ask-hub-apple": "1.2.0",
        "shilokuma-inc/notti-ios": "2.1.0",
        "shilokuma-inc/beat-tap-ios": "1.0.0"
    ]

    func refs(repository: String) async throws -> ReleaseRefs {
        switch repository {
        case "shilokuma-inc/ask-hub-apple":
            ReleaseRefs(branches: [Self.branch("1.0.0"), Self.branch("1.1.0")], tags: [Self.tag("1.0.0"), Self.tag("1.1.0")])

        case "shilokuma-inc/notti-ios":
            ReleaseRefs(branches: [Self.branch("2.0.0"), Self.branch("2.1.0")], tags: [Self.tag("2.0.0")])

        default:
            ReleaseRefs(branches: [], tags: [])
        }
    }

    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
        guard let raw = Self.marketingVersions[repository] else {
            throw ReleaseReadError.fileNotFound(path: GitHubReleaseReader.xcconfigPath, ref: ref)
        }
        return MarketingVersion(raw: raw)
    }

    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        repository == Self.draftRepository && version == Self.draftVersion ? Self.draft : nil
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        guard let draft = try await whatsNewDraft(repository: repository, version: version) else {
            return ReleaseNotes(version: version, status: .missing, languages: [], whatsNew: [:])
        }
        // 前のリリース（2.0.0）の最新情報が残っている
        return ReleaseNotes(
            version: version,
            status: .draft(draft),
            languages: ["ja"],
            whatsNew: ["ja": ConfirmedWhatsNew(version: "2.0.0", text: "・ウィジェットを追加しました")]
        )
    }

    /// 下書きのある準備中のリリース
    static let draftRepository = "shilokuma-inc/notti-ios"
    static let draftVersion = ReleaseVersion(major: 2, minor: 1, patch: 0)

    static let draft = WhatsNewDraft(
        version: "2.1.0",
        generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
        base: WhatsNewDraft.Commit(name: "v2.0.0", sha: "1111111"),
        head: WhatsNewDraft.Commit(name: "origin/develop", sha: "2222222"),
        initial: false,
        whatsNew: ["ja": "・通知の時刻を曜日ごとに選べるようにしました\n・一覧のスクロール位置がリセットされる不具合を修正しました"],
        omitted: 0,
        pullRequests: [
            pullRequest(41, "通知の時刻を曜日ごとに選べるようにする", type: "FEAT", included: true),
            pullRequest(43, "一覧のスクロール位置がリセットされる不具合を修正", type: "FIX", included: true),
            pullRequest(44, "CI の Xcode を 26.6 にする", type: "CI", included: false)
        ],
        messages: ["v2.0.0 から develop に入った PR 3 件から作りました（CI・ドキュメントだけの PR は載せていません）"]
    )

    private static func pullRequest(_ number: Int, _ title: String, type: String, included: Bool) -> WhatsNewDraft.PullRequest {
        WhatsNewDraft.PullRequest(
            number: number,
            title: title,
            type: type,
            url: URL(string: "https://github.com/\(draftRepository)/pull/\(number)"),
            mergedAt: Date(timeIntervalSince1970: 1_789_000_000 + TimeInterval(number) * 3600),
            epic: nil,
            included: included
        )
    }

    private static func branch(_ version: String) -> ReleaseRef {
        let name = ReleaseVersion.branchPrefix + version
        return ReleaseRef(name: name, sha: "0000000", version: ReleaseVersion(branch: name))
    }

    private static func tag(_ version: String) -> ReleaseRef {
        let name = ReleaseVersion.tagPrefix + version
        return ReleaseRef(name: name, sha: "0000000", version: ReleaseVersion(tag: name))
    }
}

/// デモモード・Preview・UI テスト用のリリースのワークフロー（`release-prepare.yml`・`upload.yml`・`release-notes.yml`・`release-finish.yml`）。
/// 起動したことにして GitHub には送らず、起動した時刻から実行中の run を返す。下書きのある notti-ios には、終わった準備とアップロードの run を最初から出す
actor SampleReleaseWorkflow: WorkflowProviding {
    static let files = [ReleaseProgress.uploadFile] + ReleaseWorkflow.allCases.map(\.file)

    nonisolated let file: String

    private struct Dispatch {
        var date: Date
        var ref: String
        var version: String
    }

    /// 起動したリポジトリ → 起動した時刻と ref・バージョン
    private var dispatched: [String: Dispatch] = [:]
    /// 起動したリポジトリ → 直近の run の id。本物と同じく、起動するたびに新しい（大きい）id の run にする
    private var runIDs: [String: Int] = [:]

    init(file: String = ReleaseWorkflow.prepare.file) {
        self.file = file
    }

    func availability(repository: String) async throws -> WorkflowAvailability {
        SampleReleaseReader.marketingVersions[repository] == nil ? .notFound : .active
    }

    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        guard SampleReleaseReader.marketingVersions[repository] != nil else {
            return .unsupported
        }
        let runs = try await recentRuns(repository: repository, branch: branch, event: nil, limit: 1)
        return runs.first.map(LatestWorkflowRun.run) ?? .noRuns
    }

    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
        guard let dispatch = dispatched[repository] else {
            return presetRun(repository: repository, branch: branch).map { [$0] } ?? []
        }
        return [
            WorkflowRun(
                id: runIDs[repository, default: 1],
                repository: repository,
                branch: dispatch.ref,
                headSHA: "0000000",
                status: .inProgress,
                conclusion: nil,
                event: "workflow_dispatch",
                startedAt: dispatch.date,
                url: URL(string: "https://github.com/\(repository)/actions")!,
                displayTitle: "\(title) \(dispatch.version)"
            )
        ]
    }

    func dispatch(repository: String, ref: String, inputs: [String: String]) async throws {
        runIDs[repository, default: 1] += 1
        dispatched[repository] = Dispatch(date: Date(), ref: ref, version: inputs["version"] ?? "")
    }

    private var title: String {
        ReleaseWorkflow(rawValue: file)?.actionName ?? "Upload"
    }

    /// 下書きのある準備中のリリースの、終わった準備とアップロードの run
    private func presetRun(repository: String, branch: String?) -> WorkflowRun? {
        guard repository == SampleReleaseReader.draftRepository else {
            return nil
        }
        let version = SampleReleaseReader.draftVersion
        let ref: String
        switch file {
        case ReleaseWorkflow.prepare.file:
            ref = GitHubReleaseReader.developBranch

        case ReleaseProgress.uploadFile:
            ref = version.branchName

        default:
            return nil
        }
        if let branch, branch != ref {
            return nil
        }
        return WorkflowRun(
            id: 1,
            repository: repository,
            branch: ref,
            headSHA: "2222222",
            status: .completed,
            conclusion: .success,
            event: "workflow_dispatch",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            url: URL(string: "https://github.com/\(repository)/actions")!,
            displayTitle: "\(title) \(version)"
        )
    }
}
