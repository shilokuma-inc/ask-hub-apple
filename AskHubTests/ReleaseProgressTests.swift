@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// `FakeWorkflow` の中身
private struct FakeWorkflowState {
    var availability = WorkflowAvailability.active
    var runs: [WorkflowRun] = []
    /// 起動の直前の読み直しでだけ返す run（最後に読んだ状態より後に始まった run）
    var runsAfterRead: [WorkflowRun]?
    var failure: WorkflowError?
    var dispatched: [String] = []
    var dispatchedInputs: [[String: String]] = []
    var recentRunsCalls = 0
}

/// 1 つのワークフロー。有無・run・起動の失敗を差し替えられ、起動を記録する
nonisolated private final class FakeWorkflow: WorkflowProviding {
    let file: String
    private let state = OSAllocatedUnfairLock(initialState: FakeWorkflowState())

    init(file: String) {
        self.file = file
    }

    var dispatched: [String] {
        state.withLock { $0.dispatched }
    }

    var dispatchedInputs: [[String: String]] {
        state.withLock { $0.dispatchedInputs }
    }

    func update(_ change: @Sendable (inout FakeWorkflowState) -> Void) {
        state.withLock { change(&$0) }
    }

    func availability(repository: String) async throws -> WorkflowAvailability {
        state.withLock { $0.availability }
    }

    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        state.withLock { state in
            guard state.availability != .notFound else {
                return .unsupported
            }
            return state.runs.first { $0.branch == branch }.map(LatestWorkflowRun.run) ?? .noRuns
        }
    }

    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun] {
        state.withLock { state in
            state.recentRunsCalls += 1
            if let runsAfterRead = state.runsAfterRead {
                // 一度だけ返す（次の読み取りからは runs に入れたものを返す）
                state.runsAfterRead = nil
                state.runs = runsAfterRead
            }
            return state.runs.filter { branch == nil || $0.branch == branch }
        }
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

/// release/1.1.0（タグなし）があるリポジトリ。最新情報の状態を差し替えられる
nonisolated private final class FakeReader: ReleaseReading {
    private let status = OSAllocatedUnfairLock<ReleaseNotes.Status?>(initialState: nil)
    private let whatsNew = OSAllocatedUnfairLock<[String: ConfirmedWhatsNew]>(initialState: [:])

    func set(status: ReleaseNotes.Status, whatsNew: [String: ConfirmedWhatsNew] = [:]) {
        self.status.withLock { $0 = status }
        self.whatsNew.withLock { $0 = whatsNew }
    }

    func refs(repository: String) async throws -> ReleaseRefs {
        let branch = "release/1.1.0"
        let tag = "v1.0.0"
        return ReleaseRefs(
            branches: [ReleaseRef(name: branch, sha: "1", version: ReleaseVersion(branch: branch))],
            tags: [ReleaseRef(name: tag, sha: "0", version: ReleaseVersion(tag: tag))]
        )
    }

    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
        MarketingVersion(raw: "1.0.0")
    }

    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        nil
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        let status = status.withLock { $0 } ?? .draft(ReleaseProgressTests.draft(text: "・通知を直しました"))
        return ReleaseNotes(version: version, status: status, languages: ["ja"], whatsNew: whatsNew.withLock { $0 })
    }
}

@MainActor
struct ReleaseProgressTests {
    private static let repository = "shilokuma-inc/ask-hub-apple"
    private static let version = ReleaseVersion(major: 1, minor: 1, patch: 0)

    private struct Fixture {
        let model: ReleaseRequestModel
        let reader: FakeReader
        let workflows: [String: FakeWorkflow]

        var prepare: FakeWorkflow { workflows[ReleaseWorkflow.prepare.file]! }
        var upload: FakeWorkflow { workflows[ReleaseProgress.uploadFile]! }
        var notes: FakeWorkflow { workflows[ReleaseWorkflow.notes.file]! }
        var finish: FakeWorkflow { workflows[ReleaseWorkflow.finish.file]! }
    }

    private func makeFixture() -> Fixture {
        let reader = FakeReader()
        let files = [ReleaseProgress.uploadFile] + ReleaseWorkflow.allCases.map(\.file)
        let workflows = Dictionary(uniqueKeysWithValues: files.map { ($0, FakeWorkflow(file: $0)) })
        let model = ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeReader: { _ in reader },
            makeWorkflow: { _, file in workflows[file]! },
            // テストでは取り直しを待たない
            dispatchRefreshDelay: .seconds(60)
        )
        return Fixture(model: model, reader: reader, workflows: workflows)
    }

    nonisolated static func draft(text: String) -> WhatsNewDraft {
        WhatsNewDraft(
            version: "1.1.0",
            generatedAt: nil,
            base: WhatsNewDraft.Commit(name: "v1.0.0", sha: "0"),
            head: nil,
            initial: false,
            whatsNew: ["ja": text],
            omitted: 0,
            pullRequests: [],
            messages: []
        )
    }

    private static func run(
        id: Int,
        branch: String,
        status: WorkflowRun.Status = .completed,
        conclusion: WorkflowRun.Conclusion? = .success,
        title: String? = nil
    ) -> WorkflowRun {
        WorkflowRun(
            id: id,
            repository: repository,
            branch: branch,
            headSHA: "0000000",
            status: status,
            conclusion: status == .completed ? conclusion : nil,
            event: "workflow_dispatch",
            startedAt: Date(timeIntervalSince1970: 10_000),
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/\(id)")!,
            displayTitle: title
        )
    }

    private func statuses(_ model: ReleaseRequestModel) -> [ReleaseStep.Kind: ReleaseStep.Status] {
        Dictionary(uniqueKeysWithValues: (model.context?.progress?.steps ?? []).map { ($0.id, $0.status) })
    }

    @Test func showsProgressOfUnreleasedVersionWithDraft() async {
        let fixture = makeFixture()
        let prepareRun = Self.run(id: 1, branch: "develop")
        let uploadRun = Self.run(id: 2, branch: "release/1.1.0", status: .inProgress)
        fixture.prepare.update { $0.runs = [prepareRun] }
        fixture.upload.update { $0.runs = [uploadRun] }

        await fixture.model.select(Self.repository)

        #expect(fixture.model.context?.progress?.version == Self.version)
        #expect(statuses(fixture.model) == [
            .prepare: .done, .upload: .running, .notes: .waiting, .distribution: .notStarted, .finish: .notStarted, .tag: .notStarted
        ])
        // 下書きの本文を、直せる本文として出す
        #expect(fixture.model.notes.languages == ["ja"])
        #expect(fixture.model.notes.texts == ["ja": "・通知を直しました"])
        #expect(fixture.model.notes.canConfirm())
    }

    @Test func showsMissingWorkflowsAndBlocksConfirm() async {
        let fixture = makeFixture()
        fixture.notes.update { $0.availability = .notFound }
        fixture.finish.update { $0.availability = .notFound }
        fixture.upload.update { $0.availability = .notFound }

        await fixture.model.select(Self.repository)

        #expect(statuses(fixture.model)[.upload] == .unavailable)
        #expect(statuses(fixture.model)[.finish] == .unavailable)
        #expect(fixture.model.notes.blockingReason() == "このリポジトリには最新情報の確定のワークフロー（release-notes.yml）がありません")
        #expect(!fixture.model.notes.canConfirm())
        await fixture.model.notes.confirm()
        #expect(fixture.notes.dispatched.isEmpty)
    }

    @Test func confirmsOnReleaseBranchAndKeepsPendingUntilRunAppears() async {
        let fixture = makeFixture()
        let oldRun = Self.run(id: 3, branch: "release/1.1.0")
        fixture.notes.update { $0.runs = [oldRun] }
        await fixture.model.select(Self.repository)
        fixture.model.notes.texts["ja"] = "  ・通知を直しました\n・\"引用\"も直しました\n"

        await fixture.model.notes.confirm()

        #expect(fixture.notes.dispatched == ["\(Self.repository) release/1.1.0"])
        // 前後の空白・改行は外して送る
        let expectedInputs = [
            "version": "1.1.0",
            "whats_new": #"{"ja":"・通知を直しました\n・\"引用\"も直しました"}"#
        ]
        #expect(fixture.notes.dispatchedInputs == [expectedInputs])
        #expect(fixture.model.notes.errorMessage == nil)
        #expect(fixture.model.notes.isDispatchPending())
        #expect(fixture.model.notes.blockingReason()?.contains("起動しました") == true)

        // 起動したときの run のままなら「起動した」状態のまま。直した本文は読み直しても消さない
        await fixture.model.refresh()
        #expect(fixture.model.notes.isDispatchPending())
        #expect(fixture.model.notes.texts["ja"]?.hasPrefix("  ・通知") == true)
        // id の大きい run が出たら終える。実行中のあいだは確定できない
        let newRun = Self.run(id: 4, branch: "release/1.1.0", status: .inProgress)
        fixture.notes.update { $0.runs = [newRun] }
        await fixture.model.refresh()
        #expect(!fixture.model.notes.isDispatchPending())
        #expect(statuses(fixture.model)[.notes] == .running)
        #expect(fixture.model.notes.blockingReason() == "最新情報の確定の run が実行中です。終わってから確定してください")
    }

    @Test func replacesUneditedTextWhenNotesAreConfirmed() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        #expect(!fixture.model.notes.isEdited)

        // 確定されて下書きが消えた。直していない本文は、確定した本文に入れ替える
        fixture.reader.set(status: .confirmed, whatsNew: ["ja": ConfirmedWhatsNew(version: "1.1.0", text: "・確定した本文")])
        await fixture.model.refresh()
        #expect(fixture.model.notes.texts == ["ja": "・確定した本文"])
        #expect(statuses(fixture.model)[.notes] == .done)
        #expect(statuses(fixture.model)[.distribution] == .waiting)
    }

    @Test func validatesTexts() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        let notes = fixture.model.notes

        notes.texts["ja"] = " \n "
        #expect(notes.problem(for: "ja") == "空です")
        #expect(notes.blockingReason() == "ja の最新情報が空です")

        notes.texts["ja"] = String(repeating: "あ", count: ReleaseNotesModel.maxLength)
        #expect(notes.problem(for: "ja") == nil)
        // 絵文字の異体字のように 1 文字が複数のスカラー値になるものは、ワークフロー（Python の len）と同じく多く数える
        notes.texts["ja"] = String(repeating: "あ", count: ReleaseNotesModel.maxLength - 1) + "❤️"
        #expect(notes.problem(for: "ja") == "4000 字を超えています（4001 字）")
        #expect(!notes.canConfirm())
    }

    @Test func rereadsRunsJustBeforeConfirmAndClearsNotSentReasonOnNextRead() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        // 最後に読んだ後に、確定の run が始まった
        let running = Self.run(id: 9, branch: "release/1.1.0", status: .inProgress)
        fixture.notes.update { $0.runsAfterRead = [running] }

        await fixture.model.notes.confirm()
        #expect(fixture.notes.dispatched.isEmpty)
        #expect(fixture.model.notes.errorMessage == "最新情報を確定しませんでした。最新情報の確定の run が実行中です。終わってから確定してください")

        // run が終わって読み直したら、送らなかった理由は消す
        let finished = Self.run(id: 9, branch: "release/1.1.0")
        fixture.notes.update { $0.runs = [finished] }
        await fixture.model.refresh()
        #expect(fixture.model.notes.errorMessage == nil)
        #expect(fixture.model.notes.canConfirm())
    }

    @Test func showsDispatchErrorsOfNotes() async {
        let fixture = makeFixture()
        fixture.notes.update { $0.failure = .dispatchNotSupported(message: "No ref found for: release/1.1.0") }
        await fixture.model.select(Self.repository)
        await fixture.model.notes.confirm()
        #expect(fixture.model.notes.errorMessage == "最新情報の確定を起動できませんでした。このリポジトリに release/1.1.0 ブランチがありません")
        // GitHub が断った起動の失敗は、読み直しても残す
        await fixture.model.refresh()
        #expect(fixture.model.notes.errorMessage != nil)
        #expect(!fixture.model.notes.isDispatchPending())

        let message = { (error: WorkflowError) in ReleaseNotesModel.message(for: error, version: Self.version) }
        #expect(message(.permissionDenied).hasPrefix("最新情報の確定を起動できませんでした。トークンに"))
        #expect(message(.dispatchNotSupported(message: "Unexpected inputs provided: [\"x\"]")).contains("入力（version・whats_new）"))
        #expect(message(.workflowNotFound).hasPrefix("このリポジトリには最新情報の確定のワークフロー（release-notes.yml）がありません"))
    }

    @Test func showsFinishRunFoundByRunName() async {
        let fixture = makeFixture()
        fixture.reader.set(status: .confirmed, whatsNew: ["ja": ConfirmedWhatsNew(version: "1.1.0", text: "・確定")])
        // 定期実行が develop で起動したリリース後作業は、run-name のバージョンで見分ける
        let other = Self.run(id: 5, branch: "develop", title: "Release/Finish 11.1.0")
        let finish = Self.run(id: 6, branch: "develop", status: .inProgress, title: "Release/Finish 1.1.0")
        fixture.finish.update { $0.runs = [other, finish] }
        await fixture.model.select(Self.repository)
        #expect(statuses(fixture.model)[.distribution] == .done)
        #expect(statuses(fixture.model)[.finish] == .running)
        #expect(fixture.model.context?.progress?.finishWorkflow.run?.id == 6)
    }

    @Test func matchesRunsOfVersion() {
        let run = { (branch: String, title: String?) in Self.run(id: 1, branch: branch, title: title) }
        #expect(ReleaseProgress.isRun(run("release/1.1.0", nil), of: Self.version))
        #expect(ReleaseProgress.isRun(run("develop", "Release/Notes 1.1.0"), of: Self.version))
        #expect(ReleaseProgress.isRun(run("develop", "v1.1.0 のリリース後作業"), of: Self.version))
        #expect(!ReleaseProgress.isRun(run("develop", "Release/Notes 11.1.0"), of: Self.version))
        #expect(!ReleaseProgress.isRun(run("develop", "Release/Notes 1.1.01"), of: Self.version))
        #expect(!ReleaseProgress.isRun(run("release/1.1.1", nil), of: Self.version))
        #expect(!ReleaseProgress.isRun(run("develop", nil), of: Self.version))
    }

    @Test func samplePretendsToConfirmDraft() async {
        let model = ReleaseRequestModel.sample()
        await model.select(SampleReleaseReader.draftRepository)
        #expect(model.context?.progress?.version == SampleReleaseReader.draftVersion)
        #expect(statuses(model)[.prepare] == .done)
        #expect(statuses(model)[.upload] == .done)
        #expect(statuses(model)[.notes] == .waiting)
        #expect(model.notes.draft?.pullRequests.count == 3)
        #expect(model.notes.canConfirm())

        await model.notes.confirm()
        #expect(model.notes.errorMessage == nil)
        await model.refresh()
        #expect(statuses(model)[.notes] == .running)
    }
}

/// リリース準備の起動の直前の読み直しと、送らなかった理由の消し方（前のタスクのレビューで見送った提案）
extension ReleaseProgressTests {
    @Test func prepareRereadsRunsJustBeforeDispatch() async {
        let fixture = makeFixture()
        let reader = FixedTagReader()
        let model = ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeReader: { _ in reader },
            makeWorkflow: { _, file in fixture.workflows[file]! },
            dispatchRefreshDelay: .seconds(60)
        )
        let oldRun = Self.run(id: 1, branch: "develop")
        fixture.prepare.update { $0.runs = [oldRun] }
        await model.select(Self.repository)
        // 最後に読んだ後に、別の run（id 2）が始まって終わった
        let otherRun = Self.run(id: 2, branch: "develop")
        fixture.prepare.update { $0.runsAfterRead = [otherRun] }

        await model.start()
        #expect(fixture.prepare.dispatched.count == 1)
        // 別の run（id 2）を起動した run と取り違えない
        await model.refresh()
        #expect(model.isDispatchPending())
        let startedRun = Self.run(id: 3, branch: "develop", status: .inProgress)
        fixture.prepare.update { $0.runs = [startedRun] }
        await model.refresh()
        #expect(!model.isDispatchPending())
    }

    @Test func prepareClearsNotStartedReasonOnNextRead() async {
        let fixture = makeFixture()
        let reader = FixedTagReader()
        let model = ReleaseRequestModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeReader: { _ in reader },
            makeWorkflow: { _, file in fixture.workflows[file]! },
            dispatchRefreshDelay: .seconds(60)
        )
        await model.select(Self.repository)
        let running = Self.run(id: 1, branch: "develop", status: .inProgress)
        fixture.prepare.update { $0.runsAfterRead = [running] }

        await model.start()
        #expect(fixture.prepare.dispatched.isEmpty)
        #expect(model.errorMessage == "リリース準備を始めませんでした。リリース準備の run が実行中です。終わってから始めてください")

        let finished = Self.run(id: 1, branch: "develop")
        fixture.prepare.update { $0.runs = [finished] }
        await model.refresh()
        #expect(model.errorMessage == nil)

        // GitHub が断った起動の失敗は、読み直しても残す
        fixture.prepare.update { $0.failure = .permissionDenied }
        await model.start()
        await model.refresh()
        #expect(model.errorMessage?.hasPrefix("リリース準備を起動できませんでした。") == true)
    }
}

/// タグ v1.0.0 だけがあるリポジトリ（準備中のリリースが無い）
nonisolated private struct FixedTagReader: ReleaseReading {
    func refs(repository: String) async throws -> ReleaseRefs {
        ReleaseRefs(branches: [], tags: [ReleaseRef(name: "v1.0.0", sha: "0", version: ReleaseVersion(tag: "v1.0.0"))])
    }

    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion {
        MarketingVersion(raw: "1.0.0")
    }

    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        nil
    }

    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        ReleaseNotes(version: version, status: .missing, languages: [], whatsNew: [:])
    }
}
