import AskHubKit
import Foundation

// 制御用 worktree の「最終 PR に載せる内容」が使えない epic の最終 PR を、GitHub の情報から作る。
// - 手動ループ（manual-loop）: 状態用の Issue の書き手が manual で、状態が completed
// - 自動ループ: 正常に止まり、タスクも終わっているのに「最終 PR に載せる内容」が空
extension Orchestrator {
    /// 同じリポジトリを確かめ直す間隔（GitHub への問い合わせを減らす）
    static let fallbackFinalCheckInterval: TimeInterval = 10 * 60

    func finalizeEpicsFromGitHub(statuses: [String: LoopStatus]) async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            // GitHub への問い合わせ（状態用の Issue・材料）は、リポジトリごとに間隔を空ける
            if let checkedAt = fallbackFinalChecks[key], current.timeIntervalSince(checkedAt) < Self.fallbackFinalCheckInterval {
                continue
            }
            guard let candidate = await fallbackCandidate(for: repository, status: statuses[key] ?? .idle) else {
                continue
            }
            fallbackFinalChecks[key] = current
            let epicKey = "\(key) \(candidate.branch)"
            if !finalizedEpics.contains(epicKey) {
                await createFallbackFinalPullRequest(candidate, in: repository, epicKey: epicKey)
            }
        }
    }

    private struct FallbackCandidate {
        let branch: String
        let discussion: Int?
        let reason: EpicMaterials.Reason
    }

    private func fallbackCandidate(for repository: RepositoryConfig, status: LoopStatus) async -> FallbackCandidate? {
        let key = repository.fullName.lowercased()
        // 手動ループ: 手で回している人が書いた状態用の Issue を読む（オーケストレーターの写しは古いことがある）
        if manualLoopRepositories.contains(key) {
            fallbackFinalChecks[key] = now()
            // 担当者が `askhub-manual.sh final`（手元の state の内容で作る）を流すのを、完了から `freshness` のあいだ待つ
            guard let report = await manualLoopReport(of: repository),
                  report.writer == .manual, report.state == .completed,
                  now().timeIntervalSince(report.checkedAt) >= LoopStatusReport.freshness,
                  let branch = report.epic, branch.hasPrefix("epic/") else {
                return nil
            }
            return FallbackCandidate(branch: branch, discussion: report.discussion, reason: .manualLoop)
        }
        // 自動ループ: 異常終了で止まったものは、再開して内容を書かせる（ここでは作らない）
        guard !status.stalled else {
            return nil
        }
        let snapshot = await runtime.epicSnapshot(of: repository)
        guard snapshot.loopPrepared, case .incomplete(.summaryMissing) = EpicCompletion(snapshot: snapshot, status: status),
              let branch = snapshot.branch else {
            return nil
        }
        return FallbackCandidate(branch: branch, discussion: snapshot.discussion, reason: .summaryMissing)
    }

    /// 状態用の Issue のうち、信用する author が作った open なもので最も新しいものの目印
    private func manualLoopReport(of repository: RepositoryConfig) async -> LoopStatusReport? {
        do {
            let authors = trust.authors(for: repository.fullName)
            return try await github.loopStatusIssues(in: repository.fullName)
                .filter { $0.isOpen && authors.contains($0.author) }
                .max { ($0.updatedAt, $0.number) < ($1.updatedAt, $1.number) }
                .flatMap { LoopStatusReport.parse($0.body) }
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
