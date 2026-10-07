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

    @Test func noFractionWithoutProgress() {
        let shown = display(nil)
        #expect(shown.progressFraction == nil)
        #expect(shown.progressStage == nil)
        #expect(shown.progressCountText == nil)
        // 担当 PC がいない行にも出さない
        let unassigned = LoopStatusRow(repository: "o/r", report: nil).display(now: now)
        #expect(unassigned.progressFraction == nil)
        #expect(unassigned.progressStage == nil)
    }
}
