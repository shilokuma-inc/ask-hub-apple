@testable import AskHubKit
import Foundation
import Testing

/// 完了のループを最終 PR の段階に応じて出し分ける（Discussion #808）
struct LoopCompletionStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let repository = "shilokuma-inc/ask-hub-apple"

    private func row(_ state: LoopStatusReport.State, epic: String? = "epic/mvp", repository: String = Self.repository) -> LoopStatusRow {
        let report = LoopStatusReport(state: state, epic: epic, progress: .init(completed: 5, total: 5), checkedAt: now)
        return LoopStatusRow(repository: repository, report: report, lastSeen: now)
    }

    private static func pull(
        repository: String = Self.repository,
        headBranch: String = "epic/mvp",
        checks: EpicPullRequest.ChecksState = .success,
        hasRunningChecks: Bool = false,
        mergeability: EpicPullRequest.Mergeability = .mergeable,
        codeRabbit: EpicPullRequest.CodeRabbitState = .completed
    ) -> EpicPullRequest {
        var pull = EpicPullRequest.fixture(
            checks: checks,
            hasRunningChecks: hasRunningChecks,
            mergeability: mergeability,
            codeRabbit: codeRabbit
        )
        pull.repository = repository
        pull.headBranch = headBranch
        return pull
    }

    private func status(
        _ pulls: [EpicPullRequest]?,
        epic: String? = "epic/mvp",
        repository: String = Self.repository
    ) -> LoopCompletionStatus {
        LoopCompletionStatus(repository: repository, epic: epic, pullRequests: pulls)
    }

    @Test func completedOnlyWhenFinalPullRequestCanBeMerged() {
        let mergeable = status([Self.pull()])
        #expect(mergeable == .finalPullRequest(.mergeable))
        #expect(mergeable.isCompleted)
        #expect(mergeable.statusText == "完了（最終 PR のマージ待ち）")
        #expect(mergeable.tone == .done)
        #expect(!mergeable.isProblem)
    }

    @Test func keepsCompletedWhileMergeQueueIsNotLoaded() {
        let notLoaded = status(nil)
        #expect(notLoaded == .notLoaded)
        #expect(notLoaded.isCompleted)
        #expect(notLoaded.statusText == "完了（最終 PR のマージ待ち）")
        #expect(notLoaded.systemImage == LoopStatusReport.State.completed.systemImage)
        #expect(notLoaded.tone == .done)
    }

    @Test func waitsForFinalPullRequestWhenNotFound() {
        // 一覧が空・別リポジトリの同名ブランチ・同じリポジトリの別の epic は、このループの最終 PR ではない
        let candidates: [[EpicPullRequest]] = [
            [],
            [Self.pull(repository: "shilokuma-inc/notti-ios")],
            [Self.pull(headBranch: "epic/other")]
        ]
        for pulls in candidates {
            let notFound = status(pulls)
            #expect(notFound == .finalPullRequestNotFound)
            #expect(!notFound.isCompleted)
            #expect(notFound.statusText == "最終 PR の作成待ち")
            #expect(notFound.tone == .active)
        }
        // epic が分からないループは最終 PR を探せない
        #expect(status([Self.pull()], epic: nil) == .finalPullRequestNotFound)
    }

    @Test func matchesRepositoryCaseInsensitively() {
        #expect(status([Self.pull()], repository: "Shilokuma-Inc/Ask-Hub-Apple") == .finalPullRequest(.mergeable))
        // ブランチ名は区別する
        #expect(status([Self.pull()], epic: "epic/MVP") == .finalPullRequestNotFound)
        // 別リポジトリの同名ブランチより、このリポジトリの PR を選ぶ
        let pulls = [Self.pull(repository: "shilokuma-inc/notti-ios", checks: .failure), Self.pull(checks: .pending)]
        #expect(status(pulls) == .finalPullRequest(.waitingForChecks))
    }

    private struct StageCase {
        var pull: EpicPullRequest
        var stage: EpicPullRequest.FinalStage
        var text: String
        var tone: LoopStatusDisplay.Tone
    }

    @Test func describesEachStage() {
        let cases = [
            StageCase(pull: Self.pull(checks: .pending), stage: .waitingForChecks, text: "最終 PR の CI 待ち", tone: .active),
            StageCase(pull: Self.pull(checks: .none), stage: .waitingForChecks, text: "最終 PR の CI 待ち", tone: .active),
            // 1 つ失敗しても、残りが動いている間は CI 待ち
            StageCase(
                pull: Self.pull(checks: .failure, hasRunningChecks: true),
                stage: .waitingForChecks,
                text: "最終 PR の CI 待ち",
                tone: .active
            ),
            StageCase(pull: Self.pull(checks: .failure), stage: .checksFailed, text: "最終 PR の CI 失敗", tone: .failure),
            StageCase(pull: Self.pull(mergeability: .conflicting), stage: .conflicting, text: "最終 PR がコンフリクト", tone: .paused),
            StageCase(pull: Self.pull(codeRabbit: .inProgress), stage: .waitingForReview, text: "最終 PR のレビュー待ち", tone: .active),
            StageCase(pull: Self.pull(mergeability: .unknown), stage: .checkingMergeability, text: "最終 PR のマージ可否の確認中", tone: .active)
        ]
        for testCase in cases {
            let completion = status([testCase.pull])
            #expect(completion == .finalPullRequest(testCase.stage))
            #expect(!completion.isCompleted)
            #expect(completion.statusText == testCase.text)
            #expect(completion.tone == testCase.tone)
        }
        #expect(status([Self.pull(checks: .failure)]).isProblem)
        #expect(status([Self.pull(mergeability: .conflicting)]).isProblem)
        #expect(!status([Self.pull(checks: .pending)]).isProblem)
    }

    @Test func appliesOnlyToCompletedLoops() {
        let pulls = [Self.pull(checks: .failure)]
        #expect(row(.completed).completionStatus(now: now, pullRequests: pulls) == .finalPullRequest(.checksFailed))
        #expect(row(.running).completionStatus(now: now, pullRequests: pulls) == nil)
        // 担当 PC がいない（状態が無い）ときは差し替えない
        let unassigned = LoopStatusRow(repository: Self.repository, report: nil)
        #expect(unassigned.completionStatus(now: now, pullRequests: pulls) == nil)
    }

    @Test func replacesStatusTextOfDisplay() {
        let completed = row(.completed)
        let display = completed.display(now: now)
        let applied = display.applying(completed.completionStatus(now: now, pullRequests: [Self.pull(mergeability: .conflicting)]))
        #expect(applied.statusText == "最終 PR がコンフリクト")
        #expect(applied.systemImage == "exclamationmark.triangle.fill")
        #expect(applied.tone == .paused)
        // 文言・記号・色のほかは変えない
        #expect(applied.progressText == display.progressText)
        #expect(applied.epic == display.epic)
        // 差し替えるものが無ければそのまま
        #expect(display.applying(nil) == display)
    }
}
