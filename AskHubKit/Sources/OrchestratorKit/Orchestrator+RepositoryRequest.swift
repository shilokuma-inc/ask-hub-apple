import AskHubKit
import Foundation

/// 担当リポジトリの作成・削除の依頼（`repo-request`）の処理
extension Orchestrator {
    /// 作成・削除のコマンドの制限時間（テンプレートからの作成と clone を含む）
    static let repositoryCommandTimeout: Duration = .seconds(30 * 60)

    /// 依頼 1 件を処理した結果
    enum RepositoryRequestOutcome: Equatable {
        /// 処理した。依頼 Issue に書く結果
        case succeeded(String)
        /// やり直しても成功しない（前提を満たさない・依頼の形が不正）
        case rejected(String)
        /// 失敗した。次のポーリングでやり直す
        case failed(String)
    }

    func handleRepositoryRequests(statuses: [String: LoopStatus]) async throws {
        let issues = try await github.repositoryRequests(orgs: config.orgs)
        repositoryRequestTracker.prune(keeping: issues)

        // 依頼 Issue への後処理（結果のコメント・クローズ・失敗の通知）。失敗したら次のポーリングで続きから
        for (issue, followUp) in repositoryRequestTracker.followUps(in: issues) {
            await perform(followUp, on: issue)
        }

        guard let (issue, hub) = repositoryRequestTracker.next(in: issues, config: config, trust: trust) else {
            return
        }
        let name = "\(issue.repository)#\(issue.number)"
        let outcome: RepositoryRequestOutcome
        if let request = RepositoryRequest.parse(issue.body) {
            log("\(name) の依頼を処理します: \(request.title)")
            outcome = await carryOut(request, from: issue, hub: hub, statuses: statuses)
        } else {
            outcome = .rejected("本文の先頭に依頼の目印（ask-hub:repo-request）が無いか、値が不正です")
        }

        switch outcome {
        case let .succeeded(message):
            log("\(name) の依頼を処理しました")
            repositoryRequestTracker.recordSucceeded(message, for: issue)
            // 削除では担当の organization が減り、次のポーリングの検索に出なくなることがあるので、すぐに後処理する
            await perform(.commentAndClose(message: message), on: issue)

        case let .rejected(reason):
            log("\(name) の依頼は処理できません: \(reason)")
            repositoryRequestTracker.recordRejected(issue, reason: reason)
            await perform(.reportFailure(reason: reason), on: issue)

        case let .failed(reason):
            if repositoryRequestTracker.recordFailure(for: issue, reason: reason) {
                log("\(name) の依頼を \(RepositoryRequestTracker.maxAttempts) 回処理できなかったので、やめます: \(reason)")
                await perform(.reportFailure(reason: reason), on: issue)
            } else {
                log("\(name) の依頼を処理できませんでした。次のポーリングで再試行します: \(reason)")
            }
        }
    }

    private func carryOut(
        _ request: RepositoryRequest,
        from issue: RepositoryRequestIssue,
        hub: RepositoryConfig,
        statuses: [String: LoopStatus]
    ) async -> RepositoryRequestOutcome {
        switch request {
        case let .create(newRepository):
            return await create(newRepository, hub: hub)

        case let .remove(removal):
            // 別のリポジトリの Issue から外せると、担当 PC を取り違えやすい。外すリポジトリそのものの Issue に限る
            guard removal.repository.caseInsensitiveCompare(issue.repository) == .orderedSame else {
                return .rejected("担当から外す依頼は、外したいリポジトリ（\(removal.repository)）に作ってください")
            }
            return await remove(removal, statuses: statuses)
        }
    }

    private func create(_ request: NewRepository, hub: RepositoryConfig) async -> RepositoryRequestOutcome {
        if config.repository(named: request.repository) != nil {
            return .rejected("\(request.repository) は既にこの PC の担当リポジトリです")
        }
        if request.clonesToOrchestrator, configStore == nil {
            return .rejected("設定ファイルの場所が分からないため、担当リポジトリに加えられません")
        }
        let name = String(request.repository.split(separator: "/").last ?? "")
        let checkoutPath = request.clonesToOrchestrator ? config.repositoryCommands.checkoutPath(for: name) : ""
        let arguments = config.repositoryCommands.create + [
            request.template.repository,
            request.repository,
            request.appName,
            request.bundleIdentifier,
            checkoutPath,
            request.isPrivate ? "private" : "public"
        ]
        let result: CommandResult
        do {
            // checkout はまだ無いので、依頼 Issue のある担当リポジトリで実行する（コマンドは絶対パスだけを使う）
            result = try await runtime.run(arguments, input: "", for: hub, timeout: Self.repositoryCommandTimeout)
        } catch {
            return .failed("createRepositoryCommand を起動できませんでした（\(error)）")
        }
        if let outcome = Self.failure(of: result, command: "createRepositoryCommand") {
            return outcome
        }

        var lines = ["\(request.repository) を\(request.template.title)のテンプレートから作りました: https://github.com/\(request.repository)"]
        lines += RepositoryCommandOutput.results(in: result.output).map { "- \($0)" }
        if request.clonesToOrchestrator {
            do {
                try configStore?.addRepository(request.repository, checkoutPath: checkoutPath)
            } catch {
                return .failed("リポジトリは作りましたが、担当リポジトリに加えられませんでした（\(error)）")
            }
            reloadConfig()
            lines.append("- この PC の担当リポジトリに加えました。AskHub の「新しい依頼」から開発を始められます")
        } else {
            lines.append("- 担当 PC には clone していません。手元で clone して開発してください")
        }
        lines.append("- App Store Connect でアプリ（Bundle ID: \(request.bundleIdentifier)）を作成してください（Web でのみ行えます）")
        return .succeeded(lines.joined(separator: "\n"))
    }

    private func remove(_ request: RepositoryRemoval, statuses: [String: LoopStatus]) async -> RepositoryRequestOutcome {
        guard let repository = config.repository(named: request.repository) else {
            return .rejected("\(request.repository) はこの PC の担当リポジトリではありません")
        }
        guard config.repositories.count > 1 else {
            return .rejected("最後の担当リポジトリは外せません（設定ファイルには 1 つ以上の担当リポジトリが必要です）")
        }
        guard let configStore else {
            return .rejected("設定ファイルの場所が分からないため、担当リポジトリから外せません")
        }
        let status = statuses[repository.fullName.lowercased()] ?? LoopStatus(stateFileExists: nil, processAlive: false)
        if status.processAlive {
            return .rejected("ループが動いています。止めてから依頼し直してください")
        }
        if status.stateFileExists != false, !request.force {
            return .rejected("制御用 worktree にループの state ファイルが残っている（または確かめられない）ため外しません。ループを止めてから依頼し直すか、強制して依頼し直してください")
        }

        var lines = ["\(request.repository) をこの PC の担当リポジトリから外しました（GitHub のリポジトリは残っています）"]
        if request.deletesLocalFiles {
            let arguments = config.repositoryCommands.remove
                + (request.force ? ["--force"] : [])
                + [repository.checkoutPath, repository.controlWorktreePath]
            let result: CommandResult
            do {
                result = try await runtime.run(arguments, input: "", for: repository, timeout: Self.repositoryCommandTimeout)
            } catch {
                return .failed("removeRepositoryCommand を起動できませんでした（\(error)）")
            }
            if let outcome = Self.failure(of: result, command: "removeRepositoryCommand") {
                return outcome
            }
            lines += RepositoryCommandOutput.results(in: result.output).map { "- \($0)" }
        }

        do {
            try configStore.removeRepository(repository.fullName)
        } catch {
            return .failed("担当リポジトリから外せませんでした（\(error)）")
        }
        reloadConfig()
        // アプリが「担当 PC なし」とすぐ分かるよう、担当の印を消す。消せなくても、確認時刻が古くなれば同じ扱いになる
        do {
            try await github.deleteHeartbeat(in: repository.fullName)
        } catch {
            log("\(repository.fullName) の担当の印を消せませんでした: \(error)")
        }
        lastHeartbeats[repository.fullName.lowercased()] = nil
        await closeLoopStatusIssues(of: repository)
        return .succeeded(lines.joined(separator: "\n"))
    }

    /// 状態用の Issue を閉じる。閉じられなくても担当からは外れているので、ログに出すだけにする
    private func closeLoopStatusIssues(of repository: RepositoryConfig) async {
        let trusted = trust.authors(for: repository.fullName)
        do {
            for issue in try await github.loopStatusIssues(in: repository.fullName) where issue.isOpen && trusted.contains(issue.author) {
                try await github.closeLoopStatusIssue(in: repository.fullName, number: issue.number)
            }
        } catch {
            log("\(repository.fullName) の状態用の Issue を閉じられませんでした: \(error)")
        }
        loopStatusPublisher.forget(repositoryKey: repository.fullName.lowercased())
    }

    /// コマンドが失敗していれば、その結果。成功していれば `nil`
    private static func failure(of result: CommandResult, command: String) -> RepositoryRequestOutcome? {
        guard result.status != 0 else {
            return nil
        }
        let errors = RepositoryCommandOutput.errors(in: result.output)
        let reason = errors.isEmpty ? "\(command) が終了コード \(result.status) で終わりました" : errors.joined(separator: " / ")
        return result.status == RepositoryCommandOutput.preconditionFailedStatus ? .rejected(reason) : .failed(reason)
    }

    /// 依頼 Issue への後処理を 1 段ずつ進める。コメントを重ねないよう、済んだ段は記録してから次へ進む
    private func perform(_ followUp: RepositoryRequestTracker.FollowUp, on issue: RepositoryRequestIssue) async {
        let name = "\(issue.repository)#\(issue.number)"
        do {
            switch followUp {
            case let .commentAndClose(message):
                try await github.comment(on: issue, body: "\(message)\n\n（askhub-orchestrator）")
                repositoryRequestTracker.recordCommented(issue)
                try await github.close(issue)
                repositoryRequestTracker.recordCompleted(issue)
                log("\(name) に結果をコメントしてクローズしました")

            case .close:
                try await github.close(issue)
                repositoryRequestTracker.recordCompleted(issue)
                log("\(name) をクローズしました")

            case let .reportFailure(reason):
                // 人が気づけるよう、依頼 Issue に書き残す（Issue は開いたまま。依頼し直すときは新しい Issue を作る）
                try await github.comment(on: issue, body: """
                    依頼を処理できませんでした: \(reason)
                    直したら、この Issue を閉じて AskHub から依頼し直してください。（askhub-orchestrator）
                    """)
                repositoryRequestTracker.recordFailureReported(issue)
            }
        } catch {
            log("\(name) の後処理に失敗しました（次のポーリングで続きから再試行します）: \(error)")
        }
    }
}
