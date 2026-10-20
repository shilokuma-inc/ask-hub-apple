import AskHubKit
import Foundation

/// 準備中のリリース（release ブランチがあってタグがまだ無いもの）の進み具合（Discussion #605）。
/// アプリは App Store Connect を見られないので、release ブランチ・タグ・下書きのファイル・各ワークフローの run だけで作る
struct ReleaseProgress: Equatable {
    /// 1 つのワークフローの、このリリースの状態
    struct WorkflowState: Equatable {
        var availability: WorkflowAvailability
        /// このリリースの直近の run（無ければ `nil`）
        var run: WorkflowRun?
        /// 読めなかった理由（読めたら `nil`）
        var failure: String?

        static let notFound = Self(availability: .notFound)

        /// 有効なワークフローがあって、run を読めたか
        var isUsable: Bool {
            availability.isActive && failure == nil
        }
    }

    enum NotesState: Equatable {
        case loaded(ReleaseNotes)
        case failed(String)

        var notes: ReleaseNotes? {
            if case .loaded(let notes) = self {
                return notes
            }
            return nil
        }
    }

    var version: ReleaseVersion
    /// `develop` で起動したリリース準備の、このリリースの直近の run（run-name のバージョンで見分ける）
    var prepareRun: WorkflowRun?
    /// release ブランチの `upload.yml` の run
    var upload: WorkflowState
    var notes: NotesState
    /// `release-notes.yml`
    var notesWorkflow: WorkflowState
    /// `release-finish.yml`
    var finishWorkflow: WorkflowState

    /// `upload.yml`（release ブランチへの push か、リリース準備が release ブランチで起動する）
    nonisolated static let uploadFile = "upload.yml"

    /// 読めた最新情報（読めなければ `nil`）
    var releaseNotes: ReleaseNotes? {
        notes.notes
    }

    var steps: [ReleaseStep] {
        [prepareStep, uploadStep, notesStep, distributionStep, finishStep, tagStep]
    }

    // MARK: - 段ごとの状態

    private var prepareStep: ReleaseStep {
        var step = ReleaseStep(id: .prepare, title: "リリース準備", status: .done, detail: "\(version.branchName) を作りました")
        guard let run = prepareRun else {
            // run が流れて見えなくても、release ブランチがあるので準備は始まっている
            return step
        }
        step.url = run.url
        (step.status, step.detail) = Self.runStatus(
            run,
            running: "release ブランチの用意と App Store Connect のバージョンの作成を進めています",
            success: "\(version.branchName) と App Store Connect のバージョンを用意しました",
            failure: "リリース準備の run が失敗しました。run のログを確かめてください"
        )
        return step
    }

    private var uploadStep: ReleaseStep {
        var step = ReleaseStep(id: .upload, title: "アップロード", status: .notStarted, detail: "まだ App Store Connect に上げていません")
        if let failure = upload.failure {
            step.status = .unavailable
            step.detail = failure
            return step
        }
        guard upload.availability != .notFound else {
            step.status = .unavailable
            step.detail = "このリポジトリには \(Self.uploadFile) がありません"
            return step
        }
        guard let run = upload.run else {
            return step
        }
        step.url = run.url
        (step.status, step.detail) = Self.runStatus(
            run,
            running: "バイナリを App Store Connect に上げています",
            success: "バイナリを App Store Connect に上げました（処理の状況はアプリでは見られません）",
            failure: "アップロードの run が失敗しました"
        )
        return step
    }

    private var notesStep: ReleaseStep {
        var step = ReleaseStep(id: .notes, title: "最新情報", status: .notStarted, detail: "")
        if let run = notesWorkflow.run, run.isRunning {
            step.status = .running
            step.detail = "確定した最新情報を反映しています"
            step.url = run.url
            return step
        }
        switch notes {
        case .failed(let message):
            step.status = .unavailable
            step.detail = message

        case .loaded(let notes):
            switch notes.status {
            case .draft:
                step.status = .waiting
                step.detail = "下書きがあります。確かめて確定してください"

            case .unsupportedDraft(let schemaVersion):
                step.status = .failed
                step.detail = "下書きの形（schemaVersion \(schemaVersion)）に、このアプリは対応していません。アプリを新しくしてください"

            case .confirmed:
                step.status = .done
                step.detail = "確定しました"

            case .missing:
                step.detail = "下書きも確定した最新情報もありません"
            }
        }
        // 確定済みでも、直近の確定の run（確定し直したもの）が失敗していれば、その本文は反映されていないことがある
        if let run = notesWorkflow.run, run.status == .completed, run.conclusion != .success {
            step.status = .failed
            step.detail = releaseNotes?.status == .confirmed
                ? "最新情報を確定し直した run が失敗しました。直した本文が反映されていないことがあります。run のログを確かめて、もう一度確定してください"
                : "最新情報の確定の run が失敗しました。確かめてもう一度確定してください"
            step.url = run.url
        }
        return step
    }

    private var distributionStep: ReleaseStep {
        var step = ReleaseStep(
            id: .distribution,
            title: "配信",
            status: .notStarted,
            detail: "最新情報を確定したあと、審査への提出は App Store Connect で人が行います"
        )
        if finishWorkflow.run?.isSuccessful == true {
            // リリース後作業は配信の検知のほか、GitHub で手で起動することもあるので、配信を確かめたとは言わない。
            // 実行中・失敗の run は、配信前に手で起動したものかもしれないので「済み」にしない
            step.status = .done
            step.detail = "リリース後作業の run が成功しました（配信の検知か、手での起動で始まります）。配信の状態は App Store Connect で確かめてください"
        } else if releaseNotes?.status == .confirmed {
            step.status = .waiting
            step.detail = "審査への提出と配信を待っています。App Store Connect の状態はアプリでは見られません"
        }
        return step
    }

    private var finishStep: ReleaseStep {
        var step = ReleaseStep(
            id: .finish,
            title: "リリース後作業",
            status: .notStarted,
            detail: "配信を検知すると自動で始まります（main・develop への取り込み・タグ・GitHub Release）"
        )
        if let failure = finishWorkflow.failure {
            step.status = .unavailable
            step.detail = failure
            return step
        }
        guard finishWorkflow.availability != .notFound else {
            step.status = .unavailable
            step.detail = "このリポジトリにはリリース後作業のワークフロー（\(ReleaseWorkflow.finish.file)）がありません"
            return step
        }
        guard let run = finishWorkflow.run else {
            return step
        }
        step.url = run.url
        (step.status, step.detail) = Self.runStatus(
            run,
            running: "main・develop への取り込みとタグ・GitHub Release の作成を進めています",
            success: "リリース後作業が終わりました。更新するとタグを確かめます",
            failure: "リリース後作業の run が失敗しました。コンフリクトなどを run のログで確かめてください"
        )
        return step
    }

    private var tagStep: ReleaseStep {
        // タグがあれば準備中のリリースではなくなるので、ここに来るのはタグがまだ無いときだけ
        ReleaseStep(id: .tag, title: "タグと Release", status: .notStarted, detail: "\(version.tagName) のタグと GitHub Release は、リリース後作業が作ります")
    }

    private static func runStatus(_ run: WorkflowRun, running: String, success: String, failure: String) -> (ReleaseStep.Status, String) {
        if run.isRunning {
            return (.running, running)
        }
        if run.isSuccessful {
            return (.done, success)
        }
        if run.conclusion == .cancelled {
            return (.failed, "run がキャンセルされました")
        }
        return (.failed, failure)
    }

    // MARK: - 読み取り

    /// 読み取りの結果（失敗の説明は MainActor で作るので、エラーのまま返す）
    nonisolated private struct WorkflowRead: Sendable {
        var availability: WorkflowAvailability
        var run: WorkflowRun?
        var error: (any Error)?
    }

    /// 準備中のリリースの run と最新情報を読む。どれかが読めなくても、ほかは出す（読めなかった段に理由を出す）
    static func load(
        repository: String,
        version: ReleaseVersion,
        prepareRun: WorkflowRun?,
        reader: any ReleaseReading,
        workflow: @escaping @Sendable (String) -> any WorkflowProviding
    ) async -> Self {
        async let upload = readUpload(workflow(uploadFile), repository: repository, version: version)
        async let notesWorkflow = readRuns(workflow(ReleaseWorkflow.notes.file), repository: repository, version: version)
        async let finishWorkflow = readRuns(workflow(ReleaseWorkflow.finish.file), repository: repository, version: version)
        async let notes = readNotes(reader, repository: repository, version: version)
        let notesState: NotesState
        switch await notes {
        case .success(let notes):
            notesState = .loaded(notes)

        case .failure(let error):
            notesState = .failed(ReleaseRequestModel.readingMessage(for: error))
        }
        return Self(
            version: version,
            prepareRun: prepareRun,
            upload: state(await upload, name: "アップロード", file: uploadFile),
            notes: notesState,
            notesWorkflow: state(await notesWorkflow, name: ReleaseWorkflow.notes.actionName, file: ReleaseWorkflow.notes.file),
            finishWorkflow: state(await finishWorkflow, name: ReleaseWorkflow.finish.actionName, file: ReleaseWorkflow.finish.file)
        )
    }

    /// 読み取りの結果を段の状態にする。失敗の説明は、そのワークフローの名前で出す
    private static func state(_ read: WorkflowRead, name: String, file: String) -> WorkflowState {
        WorkflowState(
            availability: read.availability,
            run: read.run,
            failure: read.error.map { ReleaseRequestModel.readingMessage(for: $0, workflow: (name: name, file: file)) }
        )
    }

    nonisolated private static func readNotes(
        _ reader: any ReleaseReading,
        repository: String,
        version: ReleaseVersion
    ) async -> Result<ReleaseNotes, any Error> {
        do {
            return .success(try await reader.releaseNotes(repository: repository, version: version))
        } catch {
            return .failure(error)
        }
    }

    /// release ブランチの `upload.yml` の直近の run
    nonisolated private static func readUpload(
        _ workflow: any WorkflowProviding,
        repository: String,
        version: ReleaseVersion
    ) async -> WorkflowRead {
        do {
            switch try await workflow.latestRun(repository: repository, branch: version.branchName) {
            case .unsupported:
                return WorkflowRead(availability: .notFound)

            case .noRuns:
                return WorkflowRead(availability: .active)

            case .run(let run):
                return WorkflowRead(availability: .active, run: run)
            }
        } catch {
            return WorkflowRead(availability: .active, error: error)
        }
    }

    /// `release-notes.yml`・`release-finish.yml` の有無と、このリリースの直近の run
    nonisolated private static func readRuns(
        _ workflow: any WorkflowProviding,
        repository: String,
        version: ReleaseVersion
    ) async -> WorkflowRead {
        do {
            var availability = try await workflow.availability(repository: repository)
            // 消したワークフローは「無い」と同じ（ReleaseRequestModel と同じ扱い）
            if availability == .disabled(state: "deleted") {
                availability = .notFound
            }
            guard availability != .notFound else {
                return WorkflowRead(availability: .notFound)
            }
            return WorkflowRead(availability: availability, run: try await latestRun(workflow, repository: repository, version: version))
        } catch {
            return WorkflowRead(availability: .active, error: error)
        }
    }

    /// このリリースの直近の run。起動した ref（release ブランチ）か、`run-name` のバージョンで見分ける
    /// （定期実行（`release-sync.yml`）が起動するリリース後作業は、どの ref で起動するかをワークフロー側で決めるので、両方を見る）
    nonisolated static func latestRun(
        _ workflow: any WorkflowProviding,
        repository: String,
        version: ReleaseVersion
    ) async throws -> WorkflowRun? {
        let runs = try await workflow.recentRuns(repository: repository, branch: nil, event: nil, limit: 20)
        return runs.first { isRun($0, of: version) }
    }

    nonisolated static func isRun(_ run: WorkflowRun, of version: ReleaseVersion) -> Bool {
        if run.branch == version.branchName {
            return true
        }
        // `1.1.0` が `11.1.0` や `1.1.01` の一部に当たらないよう、前後が数字・`.` でないものだけを見る
        guard let title = run.displayTitle else {
            return false
        }
        let text = version.description
        var searchRange = title.startIndex..<title.endIndex
        while let range = title.range(of: text, range: searchRange) {
            let before = range.lowerBound == title.startIndex ? nil : title[title.index(before: range.lowerBound)]
            let after = range.upperBound == title.endIndex ? nil : title[range.upperBound]
            let isBoundary = { (character: Character?) in character.map { !$0.isNumber && $0 != "." } ?? true }
            if isBoundary(before) && isBoundary(after) {
                return true
            }
            searchRange = range.upperBound..<title.endIndex
        }
        return false
    }
}

/// 準備中のリリースの進み具合の 1 段
struct ReleaseStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case prepare, upload, notes, distribution, finish, tag
    }

    enum Status: Equatable {
        /// 済んだ
        case done
        /// 実行中
        case running
        /// 人の操作を待っている（下書きの確定・審査への提出）
        case waiting
        /// 失敗した
        case failed
        /// まだ
        case notStarted
        /// ワークフローが無い・読めないので分からない
        case unavailable
    }

    let id: Kind
    var title: String
    var status: Status
    var detail: String
    /// run のページなど（無ければ `nil`）
    var url: URL?
}
