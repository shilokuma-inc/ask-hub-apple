@testable import AskHub
import AskHubKit
import Foundation
import Testing

@MainActor
struct ReleaseProgressTests {
    static let repository = "shilokuma-inc/ask-hub-apple"
    static let version = ReleaseVersion(major: 1, minor: 1, patch: 0)

    struct Fixture {
        let model: ReleaseRequestModel
        let reader: FakeReader
        let workflows: [String: FakeWorkflow]

        var prepare: FakeWorkflow { workflows[ReleaseWorkflow.prepare.file]! }
        var upload: FakeWorkflow { workflows[ReleaseProgress.uploadFile]! }
        var notes: FakeWorkflow { workflows[ReleaseWorkflow.notes.file]! }
        var finish: FakeWorkflow { workflows[ReleaseWorkflow.finish.file]! }
    }

    func makeFixture() -> Fixture {
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

    static func run(
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

    func statuses(_ model: ReleaseRequestModel) -> [ReleaseStep.Kind: ReleaseStep.Status] {
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

        // 入力中の本文は送った本文（前後の空白を外したもの）にそろえる
        let sent = "・通知を直しました\n・\"引用\"も直しました"
        #expect(fixture.model.notes.texts["ja"] == sent)

        // 起動したときの run のままなら「起動した」状態のまま。まだ下書きが残っていても、送った本文は読み直しで下書きに戻さない
        await fixture.model.refresh()
        #expect(fixture.model.notes.isDispatchPending())
        #expect(fixture.model.notes.texts["ja"] == sent)
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
        // 送らなかったときも読み直して、実行中の run を進み具合に出す
        #expect(statuses(fixture.model)[.notes] == .running)

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
        // 実行中のリリース後作業は配信前に手で起動したものかもしれないので、配信の段は「済み」にしない
        #expect(statuses(fixture.model)[.distribution] == .waiting)
        #expect(statuses(fixture.model)[.finish] == .running)
        #expect(fixture.model.context?.progress?.finishWorkflow.run?.id == 6)
    }

    @Test func marksDistributionDoneOnlyWhenFinishRunSucceeded() async {
        let fixture = makeFixture()
        // 下書きのまま（確定前）に手で起動して失敗したリリース後作業
        let failed = Self.run(id: 7, branch: "release/1.1.0", conclusion: .failure)
        fixture.finish.update { $0.runs = [failed] }
        await fixture.model.select(Self.repository)
        #expect(statuses(fixture.model)[.distribution] == .notStarted)
        #expect(statuses(fixture.model)[.finish] == .failed)

        let succeeded = Self.run(id: 8, branch: "release/1.1.0")
        fixture.finish.update { $0.runs = [succeeded] }
        await fixture.model.refresh()
        #expect(statuses(fixture.model)[.distribution] == .done)
        #expect(statuses(fixture.model)[.finish] == .done)
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
