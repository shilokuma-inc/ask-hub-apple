@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// `ReleaseRequestModelTests.RecordingWorkflow` の中身
private struct RecordingWorkflowState {
    var availability = WorkflowAvailability.active
    var runs: [WorkflowRun] = []
    var failure: WorkflowError?
    var dispatched: [String] = []
    var dispatchedInputs: [[String: String]] = []
}

@MainActor
struct ReleaseRequestModelTests {
    /// 起動を記録するリリース準備のワークフロー。有無・run・失敗を差し替えられる
    private final class RecordingWorkflow: WorkflowProviding {
        nonisolated let file = ReleaseWorkflow.prepare.file
        private let state = OSAllocatedUnfairLock(initialState: RecordingWorkflowState())

        var dispatched: [String] {
            state.withLock { $0.dispatched }
        }

        var dispatchedInputs: [[String: String]] {
            state.withLock { $0.dispatchedInputs }
        }

        func update(_ change: @Sendable (inout RecordingWorkflowState) -> Void) {
            state.withLock { change(&$0) }
        }

        func availability(repository: String) async throws -> WorkflowAvailability {
            state.withLock { $0.availability }
        }

        func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
            state.withLock { $0.runs.first.map(LatestWorkflowRun.run) ?? .noRuns }
        }

        func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
            state.withLock { $0.runs }
        }

        func dispatch(repository: String, ref: String, inputs: [String: String]) async throws {
            try state.withLock { state in
                if let failure = state.failure {
                    throw failure
                }
                state.dispatched.append("\(repository) \(ref)")
                state.dispatchedInputs.append(inputs)
            }
        }
    }

    private struct FixedReader: ReleaseReading {
        var refs = ReleaseRefs(branches: [], tags: [])
        var marketingVersion: String? = "1.0.0"

        func refs(repository: String) async throws -> ReleaseRefs {
            refs
        }

        func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
            guard let marketingVersion else {
                throw ReleaseReadError.fileNotFound(path: GitHubReleaseReader.xcconfigPath, ref: ref)
            }
            return MarketingVersion(raw: marketingVersion)
        }

        func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
            nil
        }

        func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
            ReleaseNotes(version: version, status: .missing, languages: [], whatsNew: [:])
        }
    }

    private static let repository = "shilokuma-inc/ask-hub-apple"

    private func makeModel(
        token: String? = "github_pat_saved",
        reader: FixedReader = FixedReader(),
        workflow: RecordingWorkflow = RecordingWorkflow()
    ) -> ReleaseRequestModel {
        ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeReader: { _ in reader },
            makeWorkflow: { _ in workflow },
            // テストでは取り直しを待たない
            dispatchRefreshDelay: .seconds(60)
        )
    }

    private static func ref(_ name: String) -> ReleaseRef {
        ReleaseRef(name: name, sha: "0000000", version: ReleaseVersion(branch: name) ?? ReleaseVersion(tag: name))
    }

    private static func run(startedAt: Date, status: WorkflowRun.Status = .completed) -> WorkflowRun {
        WorkflowRun(
            id: 1,
            repository: repository,
            branch: "develop",
            headSHA: "0000000",
            status: status,
            conclusion: status == .completed ? .success : nil,
            event: "workflow_dispatch",
            startedAt: startedAt,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/1")!
        )
    }

    @Test func fillsNextMinorAsDefaultVersionAndKeepsEditedValueOnRefresh() async {
        let model = makeModel(reader: FixedReader(marketingVersion: "1.0.3"))
        #expect(model.blockingReason() == "リリースするリポジトリを選んでください")

        await model.select(Self.repository)

        #expect(model.versionText == "1.1.0")
        #expect(model.version == ReleaseVersion("1.1.0"))
        #expect(model.blockingReason() == nil)
        #expect(model.canStart())
        // 書き換えた値は、取り直しても消さない
        model.versionText = "2.0.0"
        await model.refresh()
        #expect(model.versionText == "2.0.0")
    }

    @Test func leavesVersionEmptyWhenMarketingVersionIsUnreadable() async {
        let model = makeModel(reader: FixedReader(marketingVersion: nil))
        await model.select(Self.repository)
        #expect(model.versionText.isEmpty)
        #expect(model.context?.marketingVersionNote?.contains("MARKETING_VERSION を読めませんでした") == true)
        #expect(model.blockingReason()?.contains("MAJOR.MINOR.PATCH") == true)

        let unshaped = makeModel(reader: FixedReader(marketingVersion: "1.0"))
        await unshaped.select(Self.repository)
        #expect(unshaped.versionText.isEmpty)
        #expect(unshaped.context?.marketingVersionNote?.contains("（1.0）") == true)
    }

    @Test func rejectsMalformedVersions() async {
        let model = makeModel()
        await model.select(Self.repository)
        for text in ["1.0", "01.0.0", "1.0.0.0", "v1.0.0", "１.０.０", ""] {
            model.versionText = text
            #expect(!model.canStart(), "\(text)")
        }
        // 大小は判定しない（MARKETING_VERSION と同じ値・小さい値を止めるかはワークフローの検査が正本）
        for text in ["1.0.0", "0.9.0", " 1.2.0 "] {
            model.versionText = text
            #expect(model.canStart(), "\(text)")
        }
    }

    @Test func blocksTakenVersionAndUnreleasedBranch() async {
        let refs = ReleaseRefs(branches: [Self.ref("release/1.0.0")], tags: [Self.ref("v1.0.0"), Self.ref("v1.1.0")])
        let taken = makeModel(reader: FixedReader(refs: refs))
        await taken.select(Self.repository)
        taken.versionText = "1.1.0"
        #expect(taken.blockingReason() == "release/1.1.0 のブランチか v1.1.0 のタグがすでにあります。別のバージョンを入力してください")
        taken.versionText = "1.2.0"
        #expect(taken.canStart())

        // タグの無い別の release ブランチがあれば始めない
        let unreleased = makeModel(reader: FixedReader(refs: ReleaseRefs(branches: [Self.ref("release/1.1.0")], tags: [])))
        await unreleased.select(Self.repository)
        unreleased.versionText = "1.2.0"
        #expect(unreleased.blockingReason() == "タグの無い release ブランチ（release/1.1.0）があります。そのリリースを終えてから始めてください")
    }

    @Test func showsMissingAndDisabledWorkflow() async {
        let workflow = RecordingWorkflow()
        workflow.update { $0.availability = .notFound }
        let model = makeModel(workflow: workflow)
        await model.select(Self.repository)
        #expect(model.context?.availability == .notFound)
        #expect(model.context?.refs == nil)
        #expect(model.blockingReason() == "このリポジトリにはリリースのワークフロー（release-prepare.yml）がありません")

        workflow.update { $0.availability = .disabled(state: "disabled_manually") }
        await model.refresh()
        #expect(model.blockingReason()?.contains("無効にされています（disabled_manually）") == true)
    }

    @Test func dispatchesOnDevelopAndKeepsPendingUntilRunAppears() async {
        let workflow = RecordingWorkflow()
        let model = makeModel(workflow: workflow)
        await model.select(Self.repository)
        let now = Date(timeIntervalSince1970: 10_000.6)

        await model.start(now: now)

        #expect(workflow.dispatched == ["\(Self.repository) develop"])
        #expect(workflow.dispatchedInputs == [["version": "1.1.0"]])
        #expect(model.errorMessage == nil)
        #expect(model.isDispatchPending(now: now))
        #expect(!model.canStart(now: now))
        #expect(model.blockingReason(now: now)?.contains("起動しました") == true)

        // 起動より前の run が出ても終わらない
        let oldRun = Self.run(startedAt: now.addingTimeInterval(-60))
        workflow.update { $0.runs = [oldRun] }
        await model.refresh()
        #expect(model.isDispatchPending(now: now))
        // run の開始時刻は秒精度なので、同じ秒に始まった run で終える。実行中の run があるあいだは始められない
        let sameSecondRun = Self.run(startedAt: Date(timeIntervalSince1970: 10_000), status: .inProgress)
        workflow.update { $0.runs = [sameSecondRun] }
        await model.refresh()
        #expect(!model.isDispatchPending(now: now))
        #expect(model.blockingReason(now: now) == "リリース準備の run が実行中です。終わってから始めてください")
    }

    @Test func pendingExpiresAfterLimit() async {
        let model = makeModel()
        await model.select(Self.repository)
        let now = Date(timeIntervalSince1970: 10_000)
        await model.start(now: now)
        #expect(!model.isDispatchPending(now: now.addingTimeInterval(ReleaseRequestModel.dispatchPendingLimit + 1)))
    }

    @Test func showsDispatchErrors() async {
        let workflow = RecordingWorkflow()
        workflow.update { $0.failure = .permissionDenied }
        let model = makeModel(workflow: workflow)
        await model.select(Self.repository)
        await model.start()
        #expect(model.errorMessage?.contains("Actions の Read and write と Contents の Read") == true)
        #expect(!model.isDispatchPending())
    }

    @Test func describesErrors() {
        let message = { (error: any Error) in ReleaseRequestModel.message(for: error) }
        let rejected = { (text: String?) in message(WorkflowError.dispatchNotSupported(message: text)) }
        #expect(message(WorkflowError.workflowNotFound).hasPrefix("このリポジトリにはリリースのワークフロー（release-prepare.yml）がありません"))
        #expect(message(ReleaseReadError.permissionDenied).contains("Contents の Read"))
        #expect(rejected("Cannot trigger a 'workflow_dispatch' on a disabled workflow").contains("無効にされています"))
        #expect(rejected("Workflow does not have 'workflow_dispatch' trigger").contains("手動実行（workflow_dispatch）がありません"))
        #expect(rejected("No ref found for: develop").contains("develop ブランチがありません"))
        let inputs = rejected("Unexpected inputs provided: [\"resume\"]")
        #expect(inputs.contains("入力（version）"))
        #expect(inputs.hasSuffix("（Unexpected inputs provided: [\"resume\"]）"))
        #expect(rejected(nil).hasSuffix("受け付けませんでした"))
        #expect(message(GitHubError.rateLimited(retryAfter: .seconds(30))).contains("レート制限中"))
    }

    @Test func needsToken() async {
        let model = makeModel(token: nil)
        await model.select(Self.repository)
        #expect(model.contextState == .failed("トークンが未設定です。設定で保存してください"))
        #expect(!model.canStart())
    }

    @Test func sampleFillsDefaultAndPretendsToDispatch() async {
        let model = ReleaseRequestModel.sample()
        await model.select("shilokuma-inc/ask-hub-apple")
        #expect(model.versionText == "1.3.0")
        #expect(model.context?.refs?.latestTaggedVersion == ReleaseVersion("1.1.0"))
        await model.start()
        #expect(model.errorMessage == nil)
        await model.refresh()
        #expect(model.context?.latestRun?.isRunning == true)

        await model.select("shilokuma-inc/notti-ios")
        #expect(model.blockingReason()?.contains("release/2.1.0") == true)
        await model.select("shilokuma-inc/dotfiles")
        #expect(model.context?.availability == .notFound)
    }
}
