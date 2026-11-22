import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// hotfix（配信中の版だけを直す）と、その間に一時停止した進行中のリリース（`docs/renewal/release.md` の「hotfix」）。
/// hotfix の release ブランチは配信中の版のタグから作り、版を上げる PR を release ブランチに出す（develop には触れない）。
/// 配信したら、main と develop と一時停止したリリースの release ブランチに取り込み、一時停止したリリースの準備を作り直して再開する
extension ReleaseWatch {
    /// 版を上げる PR。ふつうのリリースは develop を次のマイナーに、hotfix は release ブランチを hotfix の版に上げる
    func nextVersionStep(_ file: SubmissionFile, settings: RepositoryFile) async throws -> ReleaseFile.NextVersion? {
        let branch = SubmissionFile.branchName(for: file.version)
        guard let hotfix = file.hotfix else {
            let reason = "\(file.version) のリリースを始めた（release ブランチ `\(branch)` を作った）ので"
            return try await nextVersionStep(
                file.repo, version: file.version, current: file.nextVersion, settings: settings, reason: reason
            )
        }
        let reason = "配信中の \(hotfix.from) を直す hotfix \(file.version) を始めた（`\(hotfix.from.tagName)` から `\(branch)` を作った）ので"
        return try await nextVersionStep(
            file.repo, version: hotfix.from, current: file.nextVersion, settings: settings, reason: reason, hotfix: (branch, file.version)
        )
    }

    /// What's New と掲載文の案の材料にする release ブランチのコミット。ふつうは作ったときの先頭、hotfix は今の先頭（直しを入れた後）
    func materialCommit(_ file: SubmissionFile, branch: SubmissionFile.Branch) async throws -> String {
        guard file.hotfix != nil else { return branch.commit }
        let head = try await github { () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: branch.name) }
        return head ?? branch.commit
    }

    // MARK: - 取り込み

    /// 配信した後に取り込む先。hotfix は、一時停止したリリースの release ブランチにも取り込む
    static func integrationBases(_ settings: RepositoryFile, file: SubmissionFile) -> [String] {
        let bases = integrationBases(settings)
        guard let suspended = file.hotfix?.suspended else { return bases }
        return bases + [SubmissionFile.branchName(for: suspended)]
    }

    /// 取り込む PR の head。hotfix を main 以外（develop・一時停止したリリースの release ブランチ）に取り込むときは、
    /// release ブランチの版の行を配信中の版に戻したブランチを作って使う（取り込む先の版を上書きせず、版の行でコンフリクトさせない）
    func integrationHead(_ file: SubmissionFile, branch: String, base: String) async throws -> String {
        guard let hotfix = file.hotfix, base != "main" else { return branch }
        let head = "askhub/hotfix-\(file.version)-into-\(base.replacingOccurrences(of: "/", with: "-"))"
        if try await github({ () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: head) }) != nil { return head }
        let snapshot: MarketingVersionSnapshot
        do {
            snapshot = try await sources.marketingVersions(file.repo, base: branch)
        } catch {
            throw ReleaseStepProblem("\(branch) の MARKETING_VERSION を読めない（\(error)）", needsHuman: false)
        }
        var files: [String: String] = [:]
        for source in snapshot.files {
            if let edited = MarketingVersionEdit.replacing(in: source.content, atMost: file.version, with: hotfix.from) {
                files[source.path] = edited
            }
        }
        guard !files.isEmpty else { return branch }
        let author = await authors.author(for: file.repo.owner)
        let message = "[chore] \(base) に取り込むため、MARKETING_VERSION を \(hotfix.from) に戻す"
        let commit = VersionCommit(files: files, snapshot: snapshot, message: message, author: author, date: context.now(), branch: head)
        _ = try await github { () throws(PullRequestError) in try await hosting.commitFiles(file.repo, commit) }
        log("\(file.repo) の \(branch) を \(base) に取り込むため、版を \(hotfix.from) に戻した \(head) を作った")
        return head
    }

    // MARK: - 再開

    /// 一時停止したリリースを、hotfix が終わったら（配信してこの release ブランチに取り込んだ・やめた）再開する。
    /// 準備（ビルド・What's New・掲載文の案・App Store Connect の版の枠）を作り直し、release ブランチの今の先頭から数え直す
    func resumeAfterHotfix(_ file: SubmissionFile) async -> SubmissionFile {
        guard let suspension = file.suspension, file.isSuspended, let branch = file.branch else { return file }
        let hotfix = try? await context.readable(SubmissionFile.self, at: StatePath.submission(file.repo, suspension.by))
        guard Self.hotfixFinished(hotfix, for: branch.name) else { return file }
        let head = try? await github { () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: branch.name) }
        do {
            let saved = try await saveResume(file, head: head ?? branch.commit)
            log("\(file.repo) の hotfix \(suspension.by) が終わったので、\(file.version) のリリースを再開した（準備を作り直す）")
            return saved
        } catch {
            report("\(file.repo) の \(file.version) のリリースを再開できない（\(error)）。次の見回りでやり直す")
            return file
        }
    }

    /// hotfix が終わった（配信して `branch` に取り込み終えた・やめた・置き換わった・記録が無い）
    static func hotfixFinished(_ hotfix: SubmissionFile?, for branch: String) -> Bool {
        guard let hotfix else { return true }
        switch hotfix.end?.reason {
        case nil: return false
        case .abandoned, .superseded: return true
        case .distributed: return (hotfix.integration ?? []).contains { $0.base == branch && $0.isDone }
        }
    }

    nonisolated private func saveResume(_ file: SubmissionFile, head: String) async throws(CommanderError) -> SubmissionFile {
        let path = StatePath.submission(file.repo, file.version)
        let now = context.timestamp
        return try await context.writingResult { () throws(CommanderError) -> SubmissionFile in
            do throws(StateFileStore.Failure) {
                let message = "\(file.repo) の \(file.version) のリリースを再開する"
                return try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                    guard file.isSuspended, !file.isEnded else { return false }
                    Self.resume(&file, head: head, at: now)
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }

    /// 再開の中身。release ブランチの先頭と時刻を今に数え直し（それより後に上げたビルドを待つ）、準備を作り直す
    static func resume(_ file: inout SubmissionFile, head: String, at now: Timestamp) {
        file.suspension?.resumedAt = now
        if var branch = file.branch {
            branch.commit = head
            branch.at = now
            file.branch = branch
        }
        file.builds = []
        file.whatsNew = nil
        file.listing = nil
        file.appReview = nil
        file.submit = nil
        file.review = []
        file.withdrawal = nil
        // hotfix に回した App Store Connect の版の枠は、もう hotfix の版なので、作り直す
        if file.appStoreVersions != nil { file.appStoreVersions = [] }
        file.problem = nil
        file.revision += 1
        file.updatedAt = now
    }
}
