#if os(macOS)
import AskHubBuild
import AskHubClaude
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

extension MachineRuntime {
    /// タスクのジョブ（`implementTask`・`reviewTask`・`fixTask`）を動かすもの。常時オンの Mac の司令塔とワーカーで同じものを組み立てる。
    ///
    /// GitHub の操作は、リポジトリの持ち主ごとのトークン（Keychain）で行う。ビルドとテストは、この Mac のビルドの枠（`capacity.build`）で、
    /// ワーカー専用のフォルダの DerivedData と Simulator の枠を使って流す。`settings` はリポジトリのビルドの設定（`repo.json` の `build`）を返す
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
            reviewer: client
        )
        return [
            .implementTask: ImplementTaskRunner(environment: environment),
            .reviewTask: ReviewTaskRunner(environment: environment),
            .fixTask: FixTaskRunner(environment: environment)
        ]
    }
}
#endif
