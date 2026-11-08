#if os(macOS)
import AskHubBuild
import AskHubClaude
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

extension MachineRuntime {
    /// タスクのジョブ（`implementTask`・`reviewTask`・`fixTask`）と、最終 PR の段取りのジョブ（`verifyBeforeFinal`・`classifyDecisions`・
    /// `openFinalPullRequest`・`reviewFinalPullRequest`・`fixFinalPullRequest`・`mergeFinalPullRequest`・`cleanUp`）を動かすもの。
    /// 常時オンの Mac の司令塔とワーカーで同じものを組み立てる。
    ///
    /// GitHub の操作は、リポジトリの持ち主ごとのトークン（Keychain）で行う。ビルドとテストは、この Mac のビルドの枠（`capacity.build`）で、
    /// ワーカー専用のフォルダの DerivedData と Simulator の枠を使って流す。`settings` はリポジトリのビルドの設定（`repo.json` の `build`）を返す。
    /// 人の意図（最終 PR への指示・判断のカードの答え・マージの承認・人がする作業で渡されたファイル）は、公開鍵の一覧（`trusted`）で署名を確かめてから読む
    public func taskRunners(
        context: CommanderContext,
        settings: @escaping @Sendable (RepositoryFullName) async throws(CommanderError) -> TaskRepositorySettings?
    ) -> [JobKind: any JobRunning] {
        let transport = GitHubURLSessionTransport()
        let token = Self.githubTokens(in: secrets)
        let client = ClaudeClient(setup: claude, runner: ProcessCommandRunner())
        let machine = BuildMachine(
            tools: BuildTools(temporaryDirectory: paths.buildTemporary),
            directories: BuildDirectories(root: paths.builds),
            runner: ProcessCommandRunner()
        )
        let trusted = trusted
        let environment = TaskJobEnvironment(
            context: context,
            git: workspace,
            pullRequests: { repo in GitHubPullRequests(repository: repo, transport: transport, token: token) },
            settings: settings,
            runner: { target in
                let builder = EpicBuilder(
                    machine: machine, settings: target.settings, epic: target.epic, sourceDirectory: target.directory, slot: target.slot
                )
                return TaskRunner(client: client, builds: EpicBuildService(builder: builder))
            },
            slots: BuildSlots(count: configuration.capacity.build),
            reviewer: client,
            verifier: { () throws(CommanderError) in try await trusted.verifier() },
            locks: epicLocks
        )
        let final = FinalJobEnvironment(
            tasks: environment,
            git: workspace,
            builds: MachineFinalBuilds(machine: machine),
            verifier: { () throws(CommanderError) in try await trusted.verifier() }
        )
        return [
            .implementTask: ImplementTaskRunner(environment: environment),
            .reviewTask: ReviewTaskRunner(environment: environment),
            .fixTask: FixTaskRunner(environment: environment),
            .verifyBeforeFinal: VerifyBeforeFinalRunner(environment: final),
            .classifyDecisions: ClassifyDecisionsRunner(environment: final),
            .openFinalPullRequest: OpenFinalPullRequestRunner(environment: final),
            .reviewFinalPullRequest: ReviewFinalPullRequestRunner(environment: final),
            .fixFinalPullRequest: FixFinalPullRequestRunner(environment: final),
            .mergeFinalPullRequest: MergeFinalPullRequestRunner(environment: final),
            .cleanUp: CleanUpRunner(environment: final)
        ]
    }

    /// 終わった epic の、この Mac に残ったもの（作業場所・手元のブランチ・DerivedData）を片付けるもの。生きている印を書いた後の見回りで流す。
    /// ジョブと同じ epic の作業場所の排他（`epicLocks`）を使う
    public func finishedEpicCleanUp(context: CommanderContext, log: @escaping @Sendable (String) -> Void) -> FinishedEpicCleanUp {
        FinishedEpicCleanUp(
            context: context, workspace: workspace, builds: BuildDirectories(root: paths.builds), locks: epicLocks, log: log
        )
    }
}
#endif
