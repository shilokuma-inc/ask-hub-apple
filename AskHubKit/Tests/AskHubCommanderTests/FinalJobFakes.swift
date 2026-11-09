import AskHubBuild
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CryptoKit
import Foundation
import os

/// リモートの作業ブランチと、手元に変更があるかだけを覚える git（作業場所のファイルには触れない）
final class FakeFinalGit: FinalGit {
    struct State {
        /// リモートのブランチ（名前 → 先頭）
        var remote: [String: String]
        /// 手元に、まだコミットしていない変更があるか（Claude が書いたら true にする）
        var dirty = false
        var commits: [String] = []
        /// `messages(after:upTo:in:)` が返すもの（"祖先..子孫" → メッセージ）。無ければ祖先でない
        var history: [String: [String]] = [:]
        var calls: [String] = []
        /// レビューの写し（差分・パス・プロジェクトの変わった行）
        var review = FinalReviewCheckout(
            directory: FakeTaskGit.directory,
            head: "",
            diff: "+struct Ranking {}",
            stat: " Ranking.swift | 1 +",
            paths: ["App/Ranking.swift"]
        )
        var removeFailure: WorkspaceError?
        /// `mergeBase(into:)` が返すもの（コンフリクトしたファイル。nil なら base がもう入っている）
        var merge: [String]?
        /// `unresolvedConflicts(_:in:)` が、印が残っているとするファイル
        var unresolved: [String] = []
        /// epic の作業場所に取り出している作業ブランチの先頭（nil なら作業場所が無い）
        var workspaceHead: String?
        /// `conflictedPaths(in:)` が返すもの（取り込みの途中で、解消していないファイル）
        var conflicted: [String] = []
    }

    static let jobDirectory = URL(fileURLWithPath: "/work/jobs/01JCJ0B000000000000000000F/repository/askhub-sandbox")
    private let state: OSAllocatedUnfairLock<State>

    init(remote: [String: String]) {
        state = OSAllocatedUnfairLock(initialState: State(remote: remote))
    }

    func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var current: State { state.withLock { $0 } }

    func checkOutEpic(_ repo: RepositoryFullName, epic: ULID, branches: FinalBranches) async throws(WorkspaceError) -> CheckedOutEpic {
        let result = state.withLock { state -> Result<CheckedOutEpic, WorkspaceError> in
            state.calls.append("checkOutEpic \(branches.epic)")
            state.dirty = false
            guard let head = state.remote[branches.epic] else { return .failure(.failed("作業ブランチ \(branches.epic) がリモートに無い")) }
            state.workspaceHead = head
            let epic = CheckedOutEpic(repo: repo, directory: FakeTaskGit.directory, branches: branches, head: head, facts: "Swift 6 で書く。")
            return .success(epic)
        }
        return try result.get()
    }

    /// 作業場所が作業ブランチを取り出したままで、先頭がリモートと同じなら、手元の変更を残して返す
    func reuseEpic(_ repo: RepositoryFullName, epic: ULID, branches: FinalBranches) async throws(WorkspaceError) -> CheckedOutEpic? {
        state.withLock { state in
            state.calls.append("reuseEpic \(branches.epic)")
            guard let head = state.workspaceHead, head == state.remote[branches.epic] else { return nil }
            return CheckedOutEpic(repo: repo, directory: FakeTaskGit.directory, branches: branches, head: head, facts: "Swift 6 で書く。")
        }
    }

    func conflictedPaths(in epic: CheckedOutEpic) async throws(WorkspaceError) -> [String] {
        state.withLock { $0.conflicted }
    }

    func commitAndPush(_ epic: CheckedOutEpic, message: String) async throws(WorkspaceError) -> String? {
        state.withLock { state in
            state.calls.append("commitAndPush")
            guard state.dirty else { return nil }
            state.dirty = false
            state.commits.append(message)
            let head = sha(Character(String(state.commits.count + 4)))
            state.remote[epic.branches.epic] = head
            state.workspaceHead = head
            return head
        }
    }

    func mergeBase(into epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]? {
        state.withLock { state in
            state.calls.append("mergeBase \(epic.branches.base)")
            // 取り込みの途中は、コミットしていない変更がある
            if state.merge != nil { state.dirty = true }
            return state.merge
        }
    }

    func unresolvedConflicts(_ paths: [String], in epic: CheckedOutEpic) async -> [String] {
        state.withLock { state in paths.filter(state.unresolved.contains) }
    }

    func messages(after ancestor: String, upTo descendant: String, in epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]? {
        state.withLock { $0.history["\(ancestor)..\(descendant)"] }
    }

    func checkOutFinal(
        _ repo: RepositoryFullName,
        job: ULID,
        branches: FinalBranches,
        head: String?
    ) async throws(WorkspaceError) -> FinalReviewCheckout {
        state.withLock { state in
            let resolved = head ?? state.remote[branches.epic] ?? ""
            state.calls.append("checkOutFinal \(resolved)")
            var review = state.review
            review.directory = Self.jobDirectory
            review.head = resolved
            review.facts = "Swift 6 で書く。"
            return review
        }
    }

    func release(_ job: ULID) async {
        state.withLock { $0.calls.append("release \(job.rawValue)") }
    }

    func removeEpic(_ repo: RepositoryFullName, epic: ULID, branch: String) async throws(WorkspaceError) {
        let failure = state.withLock { state in
            state.calls.append("removeEpic \(epic.rawValue) \(branch)")
            return state.removeFailure
        }
        if let failure { throw failure }
    }
}

/// 検証の結果を決めて返し、流したもの・片付けたものを覚える
final class FakeFinalBuilds: FinalBuilding {
    struct State {
        var run: BuildRun?
        var runs: [(kind: BuildKind, target: BuildTarget)] = []
        var removed: [ULID] = []
        var erased: [Int] = []
        var eraseProblems: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(run: BuildRun? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(run: run))
    }

    func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var current: State { state.withLock { $0 } }

    func run(_ kind: BuildKind, on target: BuildTarget) async throws(CancellationError) -> BuildRun {
        let run = state.withLock { state in
            state.runs.append((kind, target))
            return state.run
        }
        guard let run else { throw CancellationError() }
        return run
    }

    func removeProducts(of epic: ULID) throws(BuildDirectoryError) {
        state.withLock { $0.removed.append(epic) }
    }

    func eraseSimulators(slot: Int) async -> [String] {
        state.withLock { state in
            state.erased.append(slot)
            return state.eraseProblems
        }
    }
}

/// 最終 PR の段取りのジョブのテストの下ごしらえ（タスクのジョブと同じ状態リポジトリ・PR・時計・レビュー役）
struct FinalJobFixture {
    typealias Tasks = TaskJobFixture
    static let branches = FinalBranches(base: "develop", epic: "askhub/01JCJ0A0000000000000000001")
    static let head = sha("1")

    let tasks: TaskJobFixture
    let git = FakeFinalGit(remote: ["askhub/01JCJ0A0000000000000000001": FinalJobFixture.head])
    let builds = FakeFinalBuilds()
    let key = P256.Signing.PrivateKey()

    init(reviews: [CommandResult] = []) {
        tasks = TaskJobFixture(reviews: reviews)
    }

    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var pulls: FakePullRequests { tasks.pulls }
    var reviewer: ScriptedRunner { tasks.reviewer }
    var files: StateFileStore { tasks.files }

    static func settings(trustedReviewers: [String] = ["coderabbitai[bot]"]) throws -> TaskRepositorySettings {
        let build = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        return TaskRepositorySettings(
            build: build,
            childChecks: ["build / build"],
            finalChecks: ["build / build", "ui-test / ui-test"],
            trustedReviewers: trustedReviewers
        )
    }

    func environment(_ runner: FakeTaskRunner = FakeTaskRunner([]), settings: TaskRepositorySettings? = nil) throws -> FinalJobEnvironment {
        var environment = try tasks.environment(runner)
        let settings = try settings ?? Self.settings()
        environment.settings = { _ throws(CommanderError) in settings }
        let publicKeys = [keyID: key.publicKey.derRepresentation]
        return FinalJobEnvironment(
            tasks: environment,
            git: git,
            builds: builds,
            verifier: { () throws(CommanderError) in IntentVerifier(publicKeys: publicKeys) }
        )
    }

    /// 最終 PR の段取りをしている epic と、タスクをすべて終えたゴールを置く
    func prepare(stage: EpicStage = .finalizing, decisions: DecisionsFile? = nil) async throws {
        let time = Timestamp(Tasks.start)
        let epic = EpicFile(
            id: Tasks.epic,
            repo: Tasks.repo,
            title: "ランキング",
            stage: stage,
            mac: Tasks.mac,
            branch: Self.branches.epic,
            createdAt: time,
            updatedAt: time
        )
        var goal = TaskJobsTests.goal()
        for index in goal.tasks.indices {
            goal.tasks[index].state = .done
        }
        try await files.create(epic, at: StatePath.epic(Tasks.repo, Tasks.epic), message: "epic")
        try await files.create(goal, at: StatePath.goal(Tasks.repo, Tasks.epic), message: "goal")
        if let decisions { try await files.create(decisions, at: StatePath.decisions(Tasks.repo, Tasks.epic), message: "decisions") }
    }

    /// 作業ブランチから base への開いた最終 PR #512
    static func openPull(head: String = head) -> PullRequest {
        PullRequest(number: 512, state: .open, merged: false, mergeable: true, head: (branches.epic, head), baseRef: branches.base)
    }

    func job(
        _ kind: JobKind,
        _ id: String,
        input: [String: JSONValue]? = nil,
        origin: IntentReference? = nil,
        dependsOn: [ULID] = []
    ) -> JobFile {
        let time = Timestamp(Tasks.start)
        return JobFile(
            id: ULID(rawValue: "01JCJ0C00000000000000000" + id)!,
            kind: kind,
            repo: Tasks.repo,
            epic: Tasks.epic,
            assignedMac: Tasks.mac,
            needs: .init(claude: true, build: false),
            dependsOn: dependsOn,
            state: .assigned,
            input: input,
            origin: origin,
            createdAt: time,
            updatedAt: time
        )
    }

    /// 署名した人の意図を置く
    func intent(
        _ kind: String,
        target: IntentEnvelope.Target,
        version: String,
        payload: [String: JSONValue],
        signedBy signer: P256.Signing.PrivateKey? = nil
    ) async throws -> IntentReference {
        let nonce = ULID.generate(at: Tasks.start)
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Tasks.repo,
            target: target,
            targetVersion: version,
            payload: payload,
            issuedAt: Timestamp(Tasks.start),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let signature = try IntentSignature.sign(envelope: value, with: signer ?? key)
        let stored = JSONValue.object(["envelope": value, "sig": .string(signature)])
        await tasks.store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return IntentReference(keyId: keyID, nonce: nonce)
    }
}
