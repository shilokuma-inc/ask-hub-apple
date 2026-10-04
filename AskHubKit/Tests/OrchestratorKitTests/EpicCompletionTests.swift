@testable import OrchestratorKit
import Testing

struct EpicCompletionTests {
    private let stopped = LoopStatus(stateFileExists: false, processAlive: false)

    private let goal = """
        ## タスク
        - [x] 【FEAT】A | label: enhancement
        - [x] 【FEAT】B | label: enhancement  ※保留（2026-10-04）: 人の判断待ち
        - [ ] 【FEAT】C | label: enhancement  ※回答待ち（PR #12 / ask id 3）
        """

    private let state = """
        ## 保留（人の判断待ち・着手しない）
        - B: 人の判断待ち

        ## 最終 PR に載せる内容
        <!-- STEP D で promise を出す前に埋める -->
        ### 回答待ちの PR
        - #12: ask の内容

        ### 仮決め
        - #9 を参照

        ## 完了（Issue はクローズ済み）
        - #1
        """

    private func evaluate(branch: String? = "epic/mvp", goal: String?, state: String?) -> EpicCompletion {
        EpicCompletion(snapshot: EpicSnapshot(branch: branch, goal: goal, state: state), status: stopped)
    }

    @Test func completesWhenTasksAreDoneAndSummaryIsFilled() {
        let result = EpicCompletion(snapshot: EpicSnapshot(branch: "epic/mvp", goal: goal, state: state), status: stopped)
        #expect(result == .complete(branch: "epic/mvp", summary: "### 回答待ちの PR\n- #12: ask の内容\n\n### 仮決め\n- #9 を参照"))
    }

    @Test(arguments: [
        LoopStatus(stateFileExists: true, processAlive: false),
        LoopStatus(stateFileExists: false, processAlive: true),
        LoopStatus(stateFileExists: nil, processAlive: false)
    ])
    func incompleteWhileLoopIsActiveOrUnknown(status: LoopStatus) {
        let result = EpicCompletion(snapshot: EpicSnapshot(branch: "epic/mvp", goal: goal, state: state), status: status)
        #expect(result == .incomplete(.loopActive))
    }

    @Test func incompleteWhenTaskRemainsOrGoalMissing() {
        let remaining = goal + "\n- [ ] 【FEAT】D | label: enhancement"
        #expect(evaluate(goal: remaining, state: state) == .incomplete(.tasksRemain))
        #expect(evaluate(goal: nil, state: state) == .incomplete(.tasksRemain))
    }

    @Test func incompleteWhenSummaryIsOnlyTemplateComment() {
        let template = """
            ## 最終 PR に載せる内容
            <!-- STEP D で promise を出す前に埋める。人間が epic の最終 PR 本文に貼る -->

            ## 完了（Issue はクローズ済み）
            """
        #expect(evaluate(goal: goal, state: template) == .incomplete(.summaryMissing))
        #expect(evaluate(goal: goal, state: nil) == .incomplete(.summaryMissing))
    }

    @Test func ignoresNonEpicBranch() {
        for branch in ["develop", "feat/x", nil] as [String?] {
            #expect(evaluate(branch: branch, goal: goal, state: state) == .incomplete(.notEpicBranch))
        }
    }
}
