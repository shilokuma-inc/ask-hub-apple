import AskHubKit
import Foundation

/// 最終 PR のマージ後の添付の片付け（Discussion #669 の Q7。`docs/protocol.md` の「添付ファイル」の「片付け」）
extension Orchestrator {
    /// マージ済みの最終 PR を探す間隔（リポジトリごと。毎回のポーリングで API を叩かない）
    static let attachmentCleanupInterval: TimeInterval = 60 * 60

    /// 最近マージされた最終 PR のうち、まだ片付けていないものについて、その epic の添付を消す。
    /// 消すのは、ゴール元の Discussion（本文・コメント・返信）と epic の子 PR のレビューコメント（ask と返信）にある、
    /// 信用する author の目印が指すパスだけ。済んだら最終 PR に目印つきのコメントを付け、印のある PR は二度と処理しない
    func cleanUpAttachmentsOfMergedEpics() async {
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            if let last = attachmentCleanupChecks[key], now().timeIntervalSince(last) < Self.attachmentCleanupInterval {
                continue
            }
            attachmentCleanupChecks[key] = now()
            let pulls: [MergedEpicFinalPullRequest]
            do {
                pulls = try await github.mergedEpicFinalPullRequests(in: repository.fullName)
            } catch {
                log("\(repository.fullName) のマージ済みの最終 PR を取得できませんでした（添付の片付けは次の確認で）: \(error)")
                continue
            }
            let trusted = trust.authors(for: repository.fullName)
            // 信用する author が作った最終 PR だけ（ラベルは書き込み権限があれば誰でも付けられる）
            for pull in pulls where trusted.contains(pull.author) && !cleanedFinalPullRequests.contains(Self.cleanupKey(pull)) {
                do {
                    try await cleanUpAttachments(of: pull, trustedAuthors: trusted)
                } catch AttachmentCleanupError.conflict {
                    // ほかの送信が先にブランチを進めた。次のポーリングでやり直す
                    attachmentCleanupChecks[key] = nil
                    log("\(pull.repository)#\(pull.number) の添付を消す途中でブランチが先に進んでいたので、次のポーリングでやり直します")
                } catch {
                    log("\(pull.repository)#\(pull.number) の添付を片付けられませんでした（次の確認で再試行します）: \(error)")
                }
            }
        }
    }

    private static func cleanupKey(_ pull: MergedEpicFinalPullRequest) -> String {
        "\(pull.repository)#\(pull.number)".lowercased()
    }

    private func cleanUpAttachments(of pull: MergedEpicFinalPullRequest, trustedAuthors: TrustedAuthors) async throws {
        let comments = try await github.comments(in: pull.repository, issue: pull.number)
        if AttachmentCleanup.isCleaned(comments, trustedAuthors: trustedAuthors) {
            cleanedFinalPullRequests.insert(Self.cleanupKey(pull))
            return
        }
        var texts: [AuthoredText] = []
        if let discussion = pull.goalDiscussion {
            texts += try await github.discussionTexts(in: pull.repository, number: discussion)
        }
        texts += try await github.childPullRequestReviewComments(in: pull.repository, base: pull.headBranch)
        let paths = AttachmentCleanup.paths(in: texts, trustedAuthors: trustedAuthors)
        // 添付の無い epic には印を付けない（最終 PR にコメントを増やさない。再起動の後は探し直す）
        guard !paths.isEmpty else {
            cleanedFinalPullRequests.insert(Self.cleanupKey(pull))
            return
        }
        let deleted = try await github.deleteAttachments(at: paths, in: pull.repository)
        try await github.comment(
            onPullRequest: pull.number,
            in: pull.repository,
            body: AttachmentCleanup.comment(deleted: deleted, found: paths.count)
        )
        cleanedFinalPullRequests.insert(Self.cleanupKey(pull))
        log("\(pull.repository)#\(pull.number) の epic の添付 \(deleted) 件を \(AttachmentMarker.branch) から消しました")
    }
}
