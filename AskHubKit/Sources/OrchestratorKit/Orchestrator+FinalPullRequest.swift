import AskHubKit
import Foundation

// epic の最終 PR（epic-final）への指示の扱い。マージ待ちの間に信用する author が付けた指示ではループを再開する。
// 取り決めは docs/protocol.md の「最終 PR への指示」。再開の進め方は仮決め一覧と同じ（Orchestrator+InstructionResume）
extension Orchestrator {
    func handleFinalPullRequestInstructions(statuses: inout [String: LoopStatus]) async {
        for repository in config.repositories {
            let pullRequests: [EpicFinalPullRequest]
            do {
                pullRequests = try await github.epicFinalPullRequests(in: repository.fullName)
            } catch {
                log("\(repository.fullName) の最終 PR を取得できませんでした: \(error)")
                continue
            }
            let trustedAuthors = trust.authors(for: repository.fullName)
            // ラベルは書き込み権限があれば誰でも付けられるので、信用する author が作った最終 PR だけを扱う
            for pull in pullRequests where trustedAuthors.contains(pull.author) {
                let place = InstructionPlace(
                    kind: .finalPullRequest,
                    repository: pull.repository,
                    number: pull.number,
                    branch: pull.headBranch
                )
                // 1 件の失敗で、ほかの最終 PR の処理を止めない
                do {
                    try await resumeIfInstructed(at: place, in: repository, statuses: &statuses) { comments, trustedAuthors in
                        FinalPullRequestHistory.unprocessedInstructions(in: comments, trustedAuthors: trustedAuthors)
                    }
                } catch {
                    log("\(repository.fullName)#\(pull.number) の最終 PR への指示を処理できませんでした（次のポーリングで再試行します）: \(error)")
                }
            }
        }
    }
}
