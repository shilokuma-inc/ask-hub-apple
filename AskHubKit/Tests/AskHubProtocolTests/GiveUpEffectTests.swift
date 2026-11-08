@testable import AskHubProtocol
import Testing

/// 人に渡したジョブをやめたときの扱い（`JobKind.giveUpEffect`）
struct GiveUpEffectTests {
    /// やめたときの扱い。先に進めなくなるジョブは epic ごとやめ、説明とゴールの修正はジョブだけやめる。ほかの種類はやめられない
    @Test func giveUpEffectOfEachJobKind() {
        let effects: [JobKind: GiveUpEffect] = [
            .makeQuestions: .abandonsEpic,
            .reviseQuestion: .abandonsEpic,
            .checkReadiness: .abandonsEpic,
            .explain: .jobOnly,
            .reviseGoal: .jobOnly
        ]
        for kind in JobKind.allCases {
            #expect(kind.giveUpEffect == effects[kind], "\(kind.rawValue)")
        }
    }

    /// 開始した後の epic では、epic ごとやめる種類もジョブだけやめる。開始の前と終わった epic、ほかの種類は段階で変わらない
    @Test(arguments: EpicStage.allCases)
    func giveUpEffectAtEachStage(stage: EpicStage) {
        let started = [EpicStage.running, .finalizing, .reviewing].contains(stage)
        for kind in [JobKind.makeQuestions, .reviseQuestion, .checkReadiness] {
            #expect(kind.giveUpEffect(at: stage) == (started ? .jobOnly : .abandonsEpic), "\(kind.rawValue)")
        }
        #expect(JobKind.explain.giveUpEffect(at: stage) == .jobOnly)
        #expect(JobKind.reviseGoal.giveUpEffect(at: stage) == .jobOnly)
        #expect(JobKind.implementTask.giveUpEffect(at: stage) == nil)
    }
}
