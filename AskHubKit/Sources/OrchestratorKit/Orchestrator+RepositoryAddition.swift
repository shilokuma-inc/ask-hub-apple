import AskHubKit
import Foundation

/// 担当に入れる依頼（`repo-request` の `add`）の処理
extension Orchestrator {
    /// GitHub にある既存のリポジトリを、この PC の決まった場所に用意して担当リポジトリに加える
    func add(_ request: RepositoryAddition, from issue: RepositoryRequestIssue, hub: RepositoryConfig) async -> RepositoryRequestOutcome {
        if config.repository(named: request.repository) != nil {
            return .rejected("\(request.repository) は既にこの PC の担当リポジトリです")
        }
        // 依頼 Issue のある担当リポジトリで信用するだけでは足りない。書き込む先（入れるリポジトリ）でも信用する人の依頼に限る
        guard issue.isTrusted(by: await trustedAuthors(forAdding: request.repository)) else {
            return .rejected("依頼した人が \(request.repository) で信用する author ではないため、担当に入れません")
        }
        guard let configStore else {
            return .rejected("設定ファイルの場所が分からないため、担当リポジトリに加えられません")
        }
        // PC 間で担当を重ねない。別の PC が担当しているなら、先にその PC から外してもらう（Discussion #722 の Q3）
        let lastSeen: Date?
        do {
            lastSeen = try await github.heartbeatLastSeen(in: request.repository)
        } catch {
            return .failed("\(request.repository) の担当の印を読めませんでした（\(error)）")
        }
        if let lastSeen, OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now()) {
            return .rejected(
                "別の PC が担当しています（最終確認: \(lastSeen.formatted(.iso8601))）。先にその PC の担当から外してから、依頼し直してください"
            )
        }

        // 置き場所は決まった場所だけ（Discussion #722 の Q4）。既にあるかどうかはコマンドが確かめる
        let name = String(request.repository.split(separator: "/").last ?? "")
        let checkoutPath = config.repositoryCommands.checkoutPath(for: name)
        // ralph-kit の中継を入れるときに、依頼を受けた担当リポジトリの scripts/ralph-kit.sh で kit の場所を得る
        let arguments = config.repositoryCommands.add + [request.repository, checkoutPath, hub.checkoutPath]
        let result: CommandResult
        do {
            // checkout はまだ無いことがあるので、依頼 Issue のある担当リポジトリで実行する（コマンドは絶対パスだけを使う）
            result = try await runtime.run(arguments, input: "", for: hub, timeout: Self.repositoryCommandTimeout)
        } catch {
            return .failed("addRepositoryCommand を起動できませんでした（\(error)）")
        }
        if let outcome = Self.failure(of: result, command: "addRepositoryCommand") {
            return outcome
        }

        do {
            try configStore.addRepository(request.repository, checkoutPath: checkoutPath)
        } catch {
            return .failed("リポジトリは用意しましたが、担当リポジトリに加えられませんでした（\(error)）")
        }
        reloadConfig()
        // 担当の印と状態用の Issue は、次のポーリングで書く
        var lines = ["\(request.repository) をこの PC の担当リポジトリに加えました"]
        lines += RepositoryCommandOutput.results(in: result.output).map { "- \($0)" }
        return .succeeded(lines.joined(separator: "\n"))
    }

    /// 入れるリポジトリで信用する author。設定の一覧に、そのリポジトリに書き込み権限を持つアカウントを加えたもの
    /// （取得できなければ設定の一覧だけ）
    private func trustedAuthors(forAdding repository: String) async -> TrustedAuthors {
        let base = config.trustedAuthors
        guard config.trustsRepositoryWriters, let repositoryWriters,
              let writers = await repositoryWriters.writers(of: repository) else {
            return base
        }
        return base.union(writers)
    }
}
