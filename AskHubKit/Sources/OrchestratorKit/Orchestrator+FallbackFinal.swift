import AskHubKit
import Foundation

// 制御用 worktree の「最終 PR に載せる内容」が使えない epic の最終 PR を、GitHub の情報から作る。
// 同じリポジトリで複数のループ（自動ループと手動ループ・複数の手動ループ）が回るので、候補はループ（epic）ごとに出す。
// - 手動ループ（manual-loop）: 状態用の Issue の本文・ループごとのコメントのうち、書き手が manual で状態が completed のループ
// - 自動ループ: 正常に止まり、タスクも終わっているのに「最終 PR に載せる内容」が空（手動ループの有無に関わらず見る）
extension Orchestrator {
    /// 同じリポジトリの状態用の Issue を読み直す間隔・同じ epic の最終 PR を作れるかを確かめ直す間隔（GitHub への問い合わせを減らす）
    static let fallbackFinalCheckInterval: TimeInterval = 10 * 60

    func finalizeEpicsFromGitHub(statuses: [String: LoopStatus]) async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            var candidates = await manualLoopCandidates(for: repository, now: current)
            if let automatic = await automaticCandidate(for: repository, status: statuses[key] ?? .idle) {
                candidates.append(automatic)
            }
            for candidate in candidates {
                let epicKey = "\(key) \(candidate.branch)"
                // GitHub への問い合わせ（既にある PR・材料）は、epic ごとに間隔を空ける
                if finalizedEpics.contains(epicKey) {
                    continue
                }
                if let checkedAt = fallbackFinalChecks[epicKey], current.timeIntervalSince(checkedAt) < Self.fallbackFinalCheckInterval {
                    continue
                }
                fallbackFinalChecks[epicKey] = current
                await createFallbackFinalPullRequest(candidate, in: repository, epicKey: epicKey)
            }
        }
    }

    private struct FallbackCandidate {
        let branch: String
        let discussion: Int?
        let reason: EpicMaterials.Reason
    }

    /// 手動ループ: 手で回している人が書いた状態（オーケストレーターの写しは古いことがある）のうち、完了したループ。
    /// 状態用の Issue の読み直しは、リポジトリごとに間隔を空ける
    private func manualLoopCandidates(for repository: RepositoryConfig, now current: Date) async -> [FallbackCandidate] {
        let key = repository.fullName.lowercased()
        guard manualLoopRepositories.contains(key) else {
            return []
        }
        if let checkedAt = fallbackFinalChecks[key], current.timeIntervalSince(checkedAt) < Self.fallbackFinalCheckInterval {
            return []
        }
        fallbackFinalChecks[key] = current
        guard let board = await loopStatusBoard(of: repository) else {
            return []
        }
        // 開いている手動ループ（`manual-loop` の Discussion）のものだけにする。終わった昔のループのコメントが残っていても、毎回は確かめない
        // （このポーリングで取得できなければ絞らない。同じ epic では既にある PR を確かめてから作る）
        let open = manualLoops.map { loops in
            Set(loops.filter { $0.repository.lowercased() == key }.map(\.number))
        }
        return board.loops.compactMap { loop in
            let report = loop.report
            // 担当者が `askhub-manual.sh final`（手元の state の内容で作る）を流すのを、完了から `freshness` のあいだ待つ
            guard report.writer == .manual, report.state == .completed,
                  current.timeIntervalSince(report.checkedAt) >= LoopStatusReport.freshness,
                  let branch = report.epic, branch.hasPrefix("epic/") else {
                return nil
            }
            if let open, let discussion = report.discussion, !open.contains(discussion) {
                return nil
            }
            return FallbackCandidate(branch: branch, discussion: report.discussion, reason: .manualLoop)
        }
    }

    /// 自動ループ: 異常終了で止まったものは、再開して内容を書かせる（ここでは作らない）。
    /// 制御用 worktree をこの PC の手動ループが使っているときは、自動ループの epic とみなさない（回答による再開と同じ判定）
    private func automaticCandidate(for repository: RepositoryConfig, status: LoopStatus) async -> FallbackCandidate? {
        guard !status.stalled else {
            return nil
        }
        let key = repository.fullName.lowercased()
        let snapshot = await runtime.epicSnapshot(of: repository)
        guard snapshot.loopPrepared, case .incomplete(.summaryMissing) = EpicCompletion(snapshot: snapshot, status: status),
              let branch = snapshot.branch, automaticEpicBranches(in: [key: snapshot])[key] == branch else {
            return nil
        }
        return FallbackCandidate(branch: branch, discussion: snapshot.discussion, reason: .summaryMissing)
    }

    /// 状態用の Issue（信用する author が作った open なもので最も新しいもの）の本文とループごとのコメント
    private func loopStatusBoard(of repository: RepositoryConfig) async -> LoopStatusBoard? {
        do {
            let authors = trust.authors(for: repository.fullName)
            guard let issue = try await github.loopStatusIssues(in: repository.fullName)
                .filter({ $0.isOpen && authors.contains($0.author) })
                .max(by: { ($0.updatedAt, $0.number) < ($1.updatedAt, $1.number) }) else {
                return nil
            }
            let comments = try await github.loopStatusComments(in: repository.fullName, issue: issue.number)
            return LoopStatusBoard(issueBody: issue.body, comments: comments, trustedAuthors: authors)
        } catch {
            log("\(repository.fullName) の状態用の Issue を読めませんでした（手動ループの完了は次の確認で見ます）: \(error)")
            return nil
        }
    }

    private func createFallbackFinalPullRequest(_ candidate: FallbackCandidate, in repository: RepositoryConfig, epicKey: String) async {
        let name = "\(repository.fullName) の \(candidate.branch)"
        do {
            // 閉じた PR もあれば作り直さない（人がマージせずに閉じたものを復活させない）
            if try await github.existingPullRequest(in: repository.fullName, head: candidate.branch) != nil {
                finalizedEpics.insert(epicKey)
                return
            }
            let materials = try await github.epicMaterials(in: repository.fullName, branch: candidate.branch)
            guard !materials.isEmpty else {
                log("\(name) は完了しているが、epic にマージされた子 PR が無いので最終 PR を作りません")
                finalizedEpics.insert(epicKey)
                return
            }
            let summary = materials.summary(branch: candidate.branch, discussion: candidate.discussion, reason: candidate.reason)
            let body = EpicSnapshot.pullRequestBody(summary: summary, discussion: candidate.discussion)
            let number = try await github.createEpicFinalPullRequest(in: repository.fullName, head: candidate.branch, body: body)
            log("\(name) が完了したので、GitHub の情報から最終 PR #\(number) を作りました（\(candidate.reason == .manualLoop ? "手動ループ" : "最終 PR に載せる内容が空")）")
            try await github.addEpicFinalLabel(in: repository.fullName, number: number)
            finalizedEpics.insert(epicKey)
        } catch {
            log("\(name) の最終 PR を GitHub の情報から作れませんでした（次の確認で再試行します）: \(error)")
        }
    }
}
