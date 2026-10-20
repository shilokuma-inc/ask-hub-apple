import AskHubKit
import Foundation

extension ReleaseRequestModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続せず、起動しても送ったことにするだけ
    static func sample() -> ReleaseRequestModel {
        let workflow = SampleReleaseWorkflow()
        return ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeReader: { _ in SampleReleaseReader() },
            makeWorkflow: { _ in workflow },
            dispatchRefreshDelay: .seconds(1)
        )
    }
}

/// デモモード・Preview・UI テスト用のリリースの状態（`SampleIdeaRequester` のリポジトリに合わせる）。
/// - ask-hub-apple: `MARKETING_VERSION` 1.2.0・リリース済みのタグ v1.0.0 / v1.1.0（既定値は 1.3.0）
/// - notti-ios: タグの無い release/2.1.0 がある（準備中のリリースがあるので始められない）
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
        nil
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        ReleaseNotes(version: version, status: .missing, languages: [], whatsNew: [:])
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

/// デモモード・Preview・UI テスト用のリリース準備のワークフロー。起動したことにして GitHub には送らず、起動した時刻から実行中の run を返す
actor SampleReleaseWorkflow: WorkflowProviding {
    nonisolated let file = ReleaseWorkflow.prepare.file

    /// 起動したリポジトリ → 起動した時刻とバージョン
    private var dispatched: [String: (date: Date, version: String)] = [:]
    /// 起動したリポジトリ → 直近の run の id。本物と同じく、起動するたびに新しい（大きい）id の run にする
    private var runIDs: [String: Int] = [:]

    func availability(repository: String) async throws -> WorkflowAvailability {
        SampleReleaseReader.marketingVersions[repository] == nil ? .notFound : .active
    }

    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        try await recentRuns(repository: repository, branch: branch, event: nil, limit: 1).first.map(LatestWorkflowRun.run) ?? .noRuns
    }

    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
        guard let dispatch = dispatched[repository] else {
            return []
        }
        return [
            WorkflowRun(
                id: runIDs[repository, default: 1],
                repository: repository,
                branch: branch ?? GitHubReleaseReader.developBranch,
                headSHA: "0000000",
                status: .inProgress,
                conclusion: nil,
                event: "workflow_dispatch",
                startedAt: dispatch.date,
                url: URL(string: "https://github.com/\(repository)/actions")!,
                displayTitle: "リリース準備 \(dispatch.version)"
            )
        ]
    }

    func dispatch(repository: String, ref: String, inputs: [String: String]) async throws {
        runIDs[repository, default: 0] += 1
        dispatched[repository] = (Date(), inputs["version"] ?? "")
    }
}
