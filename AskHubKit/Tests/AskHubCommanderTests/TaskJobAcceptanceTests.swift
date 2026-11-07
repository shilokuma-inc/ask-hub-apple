import AskHubClaude
@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 常時オンの Mac の司令塔が、タスクのジョブを引き受けるか
struct TaskJobAcceptanceTests {
    struct StubRunner: JobRunning {
        func execute(_ job: JobFile) async throws(CommanderError) -> JobResult { JobResult() }
    }

    static let commander = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)

    func makeLoop(taskRunners: [JobKind: any JobRunning]) -> CommanderLoop {
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        return CommanderLoop(
            context: CommanderContext(store: InMemoryStateStore(), mac: Self.commander) { Self.now },
            settings: .init(capacity: .init(claude: 2, build: 1), commanderVersion: "0.1.0"),
            verifier: { IntentVerifier(publicKeys: [:]) },
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: ScriptedRunner([])),
            workspace: FixedWorkspace(directory: FileManager.default.temporaryDirectory),
            status: { CommanderLoop.MachineStatus(diskFreeGB: 100, load: 0.5, selfCheck: selfCheck) },
            log: { _ in },
            taskRunners: taskRunners
        )
    }

    func job(_ kind: JobKind, on mac: String, _ id: String) -> JobFile {
        let time = Timestamp(Self.now)
        return JobFile(
            id: ULID(rawValue: "01JCJ0C00000000000000000" + id)!,
            kind: kind,
            repo: TaskJobFixture.repo,
            epic: TaskJobFixture.epic,
            task: "t1",
            assignedMac: MacName(rawValue: mac)!,
            needs: .init(claude: true, build: kind != .reviewTask),
            state: .assigned,
            createdAt: time,
            updatedAt: time
        )
    }

    @Test func commanderTakesTaskJobsAssignedToItsOwnMacOnly() async throws {
        let runners: [JobKind: any JobRunning] = [.implementTask: StubRunner(), .reviewTask: StubRunner(), .fixTask: StubRunner()]
        let loop = makeLoop(taskRunners: runners)
        #expect(loop.slots.kinds.isSuperset(of: [.implementTask, .reviewTask, .fixTask]))
        let dispatched = (loop.worker(IntentVerifier(publicKeys: [:])).runner as? JobDispatcher)?.runners
        // push や子 PR の作成をするので、元になった人の意図の署名を確かめてから動かす
        #expect((dispatched?[.implementTask] as? OriginCheckedRunner)?.runner is StubRunner)
        #expect(dispatched?[.makeQuestions] is ClaudeJobRunner)

        // 開始のときに選ばれた Mac（ほかの Mac）宛てのものは引き受けない
        let own = job(.implementTask, on: "mac-mini", "01")
        let other = job(.implementTask, on: "macbook-a", "02")
        let review = job(.reviewTask, on: "mac-mini", "03")
        let picked = await loop.slots.pick(from: [own, other, review], now: Self.now)
        #expect(picked.map(\.id) == [own.id, review.id])

        // タスクのジョブを渡さなければ、引き受けない
        #expect(!makeLoop(taskRunners: [:]).slots.kinds.contains(.implementTask))
    }
}
