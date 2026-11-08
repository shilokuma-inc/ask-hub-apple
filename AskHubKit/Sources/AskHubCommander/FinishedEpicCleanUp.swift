import AskHubBuild
import AskHubProtocol
import Foundation

/// 終わった（マージした・やめた）epic の、この Mac に残ったもの（epic の作業場所・手元の epic のブランチ・DerivedData）を、
/// 定期の見回りで消す（`docs/renewal/operations.md` の「容量」）。
///
/// 片付け（`cleanUp`）は epic の Mac だけで動くので、次のものは片付けでは消えない。
///
/// - epic の Mac がオフラインの間に、常時オンの Mac で最終 PR を直した（`fixFinalPullRequest`）ときの、常時オンの Mac の作業場所と DerivedData
/// - epic の Mac が、片付けを見張る間（マージから 7 日。`EpicFile.cleanUpWindow`）に戻らなかったときの、epic の Mac のもの
/// - 開始した後にやめた epic のもの
///
/// 状態リポジトリで終わったと確かめられ、終わってから `lifetime` たった epic のものだけを消す（読めない・見つからない epic のものは残す）。
/// ジョブが作業場所を使っている epic は、待たずに次の見回りに回す。Simulator の枠は epic をまたいで使い回すので触れない。
/// 作業場所は役割（司令塔・ワーカー）ごとのフォルダにあるので、それぞれが自分のフォルダを見回る
public struct FinishedEpicCleanUp: Sendable {
    /// 終わってから消すまでの時間の既定。終わった直後に、人が残りものを確かめられるよう少し残す
    public static let defaultLifetime: TimeInterval = 24 * 60 * 60

    public var context: CommanderContext
    public var workspace: GitRepositoryWorkspace
    public var builds: BuildDirectories
    /// epic の作業場所の排他（ジョブと同じもの。`TaskJobEnvironment.locks`）
    public var locks: EpicLocks
    public var lifetime: TimeInterval
    public var log: @Sendable (String) -> Void

    public init(
        context: CommanderContext,
        workspace: GitRepositoryWorkspace,
        builds: BuildDirectories,
        locks: EpicLocks,
        lifetime: TimeInterval = defaultLifetime,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.workspace = workspace
        self.builds = builds
        self.locks = locks
        self.lifetime = lifetime
        self.log = log
    }

    /// 1 回見回る。状態リポジトリを読めなければ、何も消さずに次の見回りに回す
    public func run() async {
        let workspaces = Set(workspace.epicsWithWorkspace())
        let products = Set(builds.epics())
        let local = workspaces.union(products)
        guard !local.isEmpty else { return }
        let finished: [EpicFile]
        do {
            finished = try await finishedEpics(among: local)
        } catch {
            log("終わった epic を状態リポジトリから読めないので、この Mac に残ったものの片付けは次の見回りに回す（\(error)）")
            return
        }
        for epic in finished {
            guard await locks.acquireIfFree(epic.id) else { continue }
            var problems: [String] = []
            if workspaces.contains(epic.id) {
                let branch = epic.branch ?? PrepareWorkspaceRunner.branch(of: epic.id)
                do {
                    try await workspace.removeEpic(epic.repo, epic: epic.id, branch: branch)
                } catch {
                    problems.append("epic の作業場所（\(error.detail)）")
                }
            }
            if products.contains(epic.id) {
                do {
                    try builds.remove(epic.id)
                } catch {
                    problems.append("DerivedData（\(error.message)）")
                }
            }
            await locks.release(epic.id)
            if problems.isEmpty {
                log("終わった epic \(epic.id)（\(epic.stage.rawValue)）の、この Mac に残った作業場所と DerivedData を消した")
            } else {
                log("終わった epic \(epic.id) の、この Mac に残ったもので消せないものがあった（\(problems.joined(separator: "・"))）。次の見回りでやり直す")
            }
        }
    }

    /// `local` のうち、状態リポジトリで終わってから `lifetime` たった epic。読めない（知らない版など）epic は除く
    func finishedEpics(among local: Set<ULID>) async throws(CommanderError) -> [EpicFile] {
        let now = context.now()
        var finished: [EpicFile] = []
        for repo in try await context.repositories() {
            for name in try await context.directories(in: StatePath.epics(repo)) {
                guard let id = ULID(rawValue: name), local.contains(id),
                      let epic = try await context.readable(EpicFile.self, at: StatePath.epic(repo, id)),
                      epic.id == id, epic.repo == repo, epic.isFinished,
                      now.timeIntervalSince(epic.updatedAt.date) >= lifetime else { continue }
                finished.append(epic)
            }
        }
        return finished
    }
}
