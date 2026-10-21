import Foundation

/// 依頼から Discussion を作る前に、依頼先のリポジトリで Discussion を作れるかを確かめる（Issue #719）。
/// テンプレートから作ったリポジトリは Discussions が無効のままで、claude が Discussion を作れずに終わっていた
extension Orchestrator {
    /// 依頼先で質問付きの Discussion を作れるなら `true`。Discussions が無効なら有効にする。
    /// 作れなければ claude を起動せず（試行に数えない）、理由を依頼 Issue に 1 回だけコメントする。直れば次のポーリングで続きから進む
    func prepareDiscussions(for issue: IdeaRequestIssue) async -> Bool {
        let name = "\(issue.repository)#\(issue.number)"
        let settings: DiscussionSettings
        do {
            settings = try await github.discussionSettings(in: issue.repository)
        } catch {
            log("\(name) の依頼先の Discussions の設定を確かめられませんでした（次のポーリングで確かめ直します）: \(error)")
            return false
        }
        guard let problem = settings.ideaProblem else {
            return true
        }
        // 有効にできなかったことを書いた後は、ポーリングごとに有効にし直さない（人が有効にするのを待つ）
        if problem == .disabled, ideaTracker.needsReport(problem, for: issue) {
            do {
                try await github.enableDiscussions(in: issue.repository)
                log("\(issue.repository) の Discussions が無効だったので、有効にしました（\(name) の依頼のため）")
                return await categoryIsReady(after: name, in: issue.repository)
            } catch {
                log("\(issue.repository) の Discussions を有効にできませんでした: \(error)")
            }
        }
        await report(problem, on: issue)
        return false
    }

    /// Discussions を有効にした直後に、既定のカテゴリ「Ideas」ができたかを確かめる。
    /// まだ無ければ、依頼 Issue には書かずに次のポーリングで確かめ直す（作成が間に合っていないだけのことがあるため）
    private func categoryIsReady(after name: String, in repository: String) async -> Bool {
        do {
            if try await github.discussionSettings(in: repository).ideaProblem == nil {
                return true
            }
            log("\(repository) にカテゴリ「\(IdeaPrompt.category)」がまだありません（\(name) は次のポーリングで確かめ直します）")
        } catch {
            log("\(name) の依頼先の Discussions の設定を確かめられませんでした（次のポーリングで確かめ直します）: \(error)")
        }
        return false
    }

    /// Discussion を作れない理由を依頼 Issue に書く。同じ理由は重ねず、書けなければ次のポーリングで書き直す
    private func report(_ problem: IdeaDiscussionProblem, on issue: IdeaRequestIssue) async {
        let name = "\(issue.repository)#\(issue.number)"
        let message = problem.message(for: issue.repository)
        guard ideaTracker.needsReport(problem, for: issue) else {
            return
        }
        log("\(name) の依頼先で Discussion を作れないので、claude を起動せずに待ちます: \(message)")
        do {
            try await github.comment(on: issue, body: """
                質問付きの Discussion を作れません: \(message)
                直ると、次のポーリングで Discussion を作ります（依頼を出し直す必要はありません）。（askhub-orchestrator）
                """)
            ideaTracker.recordReported(problem, for: issue)
        } catch {
            log("\(name) に Discussion を作れない理由をコメントできませんでした（次のポーリングで再試行します）: \(error)")
        }
    }
}
