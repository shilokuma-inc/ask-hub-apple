@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusProgressTests {
    private typealias Stage = LoopStatusDisplay.ProgressStage
    private typealias Progress = LoopStatusReport.Progress

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func display(_ progress: Progress?) -> LoopStatusDisplay {
        let report = LoopStatusReport(state: .running, epic: "epic/x", progress: progress, checkedAt: now)
        return LoopStatusRow(repository: "o/r", report: report).display(now: now)
    }

    @Test func fractionOfCompletedTasks() {
        #expect(Progress(completed: 0, total: 12).fraction == 0)
        #expect(Progress(completed: 6, total: 12).fraction == 0.5)
        #expect(Progress(completed: 12, total: 12).fraction == 1)
    }

    @Test func clampsAbnormalProgress() {
        #expect(Progress(completed: 0, total: 0).fraction == 0)
        #expect(Progress(completed: 3, total: 0).fraction == 0)
        #expect(Progress(completed: 13, total: 12).fraction == 1)
        #expect(Progress(completed: -1, total: 12).fraction == 0)
        #expect(Progress(completed: 1, total: -4).fraction == 0)
    }

    @Test func stagesByFraction() {
        #expect(Stage(fraction: 0) == .starting)
        #expect(Stage(fraction: 0.5) == .halfway)
        #expect(Stage(fraction: 0.8) == .nearlyDone)
        #expect(Stage(fraction: 1) == .completed)
    }

    @Test func boundaryBelongsToUpperStage() {
        // 境界ちょうど（1/3・2/3・100%）は上の段階に含める
        #expect(Stage(fraction: Progress(completed: 3, total: 9).fraction) == .halfway)
        #expect(Stage(fraction: Progress(completed: 4, total: 12).fraction) == .halfway)
        #expect(Stage(fraction: Progress(completed: 2, total: 9).fraction) == .starting)
        #expect(Stage(fraction: Progress(completed: 6, total: 9).fraction) == .nearlyDone)
        #expect(Stage(fraction: Progress(completed: 8, total: 12).fraction) == .nearlyDone)
        #expect(Stage(fraction: Progress(completed: 5, total: 9).fraction) == .halfway)
        #expect(Stage(fraction: Progress(completed: 11, total: 12).fraction) == .nearlyDone)
        #expect(Stage(fraction: Progress(completed: 12, total: 12).fraction) == .completed)
    }

    @Test func displayCarriesFractionAndStage() {
        let shown = display(Progress(completed: 5, total: 12))
        #expect(shown.progressFraction == 5.0 / 12.0)
        #expect(shown.progressStage == .halfway)
        #expect(shown.progressCountText == "5 / 12")
        #expect(shown.progressText == "5 / 12 タスク完了")
        #expect(display(Progress(completed: 0, total: 0)).progressStage == .starting)
    }

    @Test func separatesDeferredTasks() {
        let progress = Progress(completed: 5, total: 12, deferred: 2)
        #expect(progress.deferredCount == 2)
        #expect(progress.doneFraction == 3.0 / 12.0)
        #expect(progress.deferredFraction == 2.0 / 12.0)
        #expect(progress.countTextWithDeferred == "5 / 12（保留 2）")
        #expect(progress.textWithDeferred == "5 / 12 タスク完了（うち保留 2）")
    }

    @Test func clampsAbnormalDeferredCount() {
        #expect(Progress(completed: 5, total: 12, deferred: -1).deferredCount == 0)
        #expect(Progress(completed: 5, total: 12, deferred: 9).deferredCount == 5)
        #expect(Progress(completed: 5, total: 12, deferred: 9).doneFraction == 0)
        #expect(Progress(completed: 3, total: 0, deferred: 1).deferredFraction == 0)
        // 完了と保留を足しても 1 を超えない
        let over = Progress(completed: 13, total: 12, deferred: 2)
        #expect(over.doneFraction == 11.0 / 12.0)
        #expect(over.doneFraction + over.deferredFraction == 1)
    }

    @Test func displayStacksDeferredTasks() {
        let shown = display(Progress(completed: 5, total: 12, deferred: 2))
        #expect(shown.progressFraction == 3.0 / 12.0)
        #expect(shown.progressDeferredFraction == 2.0 / 12.0)
        // 段階は保留を除いた割合で決める
        #expect(shown.progressStage == .starting)
        #expect(shown.progressCountText == "5 / 12（保留 2）")
        #expect(shown.progressText == "5 / 12 タスク完了（うち保留 2）")

        // すべて閉じても、保留があれば「完了」の段階にはしない
        let finished = display(Progress(completed: 9, total: 9, deferred: 2))
        #expect(finished.progressFraction == 7.0 / 9.0)
        #expect(finished.progressStage == .nearlyDone)
    }

    @Test func fallsBackWithoutDeferredCount() {
        // 古いオーケストレーター（キーが無い）・保留が 0 件なら、保留を区別しない今までの表示
        for progress in [Progress(completed: 5, total: 12), Progress(completed: 5, total: 12, deferred: 0)] {
            let shown = display(progress)
            #expect(shown.progressFraction == 5.0 / 12.0)
            #expect(shown.progressDeferredFraction == nil)
            #expect(shown.progressStage == .halfway)
            #expect(shown.progressCountText == "5 / 12")
            #expect(shown.progressText == "5 / 12 タスク完了")
        }
    }

    @Test func noFractionWithoutProgress() {
        let shown = display(nil)
        #expect(shown.progressFraction == nil)
        #expect(shown.progressStage == nil)
        #expect(shown.progressDeferredFraction == nil)
        #expect(shown.progressCountText == nil)
        // 担当 PC がいない行にも出さない
        let unassigned = LoopStatusRow(repository: "o/r", report: nil).display(now: now)
        #expect(unassigned.progressFraction == nil)
        #expect(unassigned.progressStage == nil)
    }
}
