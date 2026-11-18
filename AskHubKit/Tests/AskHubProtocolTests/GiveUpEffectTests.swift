@testable import AskHubProtocol
import Testing

/// 人に渡したジョブをやめたときの扱い（`JobKind.giveUpEffect`）
struct GiveUpEffectTests {
    /// やめたときの扱い。先に進めなくなるジョブは epic ごとやめ、説明・ゴールの修正・片付けはジョブだけやめ、撮影は撮らずに進む。
    /// 名前だけで作らない種類はやめられない
    @Test func giveUpEffectOfEachJobKind() {
        let effects: [JobKind: GiveUpEffect] = [
            .makeQuestions: .abandonsEpic,
            .reviseQuestion: .abandonsEpic,
            .checkReadiness: .abandonsEpic,
            .explain: .jobOnly,
            .reviseGoal: .jobOnly,
            .prepareWorkspace: .abandonsEpic,
            .implementTask: .abandonsEpic,
            .reviewTask: .abandonsEpic,
            .fixTask: .abandonsEpic,
            .verifyBeforeFinal: .abandonsEpic,
            .classifyDecisions: .abandonsEpic,
            .openFinalPullRequest: .abandonsEpic,
            .reviewFinalPullRequest: .abandonsEpic,
            .fixFinalPullRequest: .abandonsEpic,
            .mergeFinalPullRequest: .abandonsEpic,
            .captureScreenshots: .skipsScreenshots,
            .cleanUp: .jobOnly
        ]
        for kind in JobKind.allCases {
            #expect(kind.giveUpEffect == effects[kind], "\(kind.rawValue)")
        }
    }

    /// 開始した後の epic に残っていた開始の前のジョブは、ジョブだけやめる。実装・最終 PR の段取りのジョブは、段階で変わらず epic ごとやめる
    @Test(arguments: EpicStage.allCases)
    func giveUpEffectAtEachStage(stage: EpicStage) {
        let started = [EpicStage.running, .finalizing, .reviewing].contains(stage)
        for kind in [JobKind.makeQuestions, .reviseQuestion, .checkReadiness] {
            #expect(kind.giveUpEffect(at: stage) == (started ? .jobOnly : .abandonsEpic), "\(kind.rawValue)")
        }
        #expect(JobKind.explain.giveUpEffect(at: stage) == .jobOnly)
        #expect(JobKind.reviseGoal.giveUpEffect(at: stage) == .jobOnly)
        #expect(JobKind.implementTask.giveUpEffect(at: stage) == .abandonsEpic)
        #expect(JobKind.mergeFinalPullRequest.giveUpEffect(at: stage) == .abandonsEpic)
        #expect(JobKind.captureScreenshots.giveUpEffect(at: stage) == .skipsScreenshots)
        #expect(JobKind.cleanUp.giveUpEffect(at: stage) == .jobOnly)
        #expect(JobKind.notify.giveUpEffect(at: stage) == nil)
    }
}
