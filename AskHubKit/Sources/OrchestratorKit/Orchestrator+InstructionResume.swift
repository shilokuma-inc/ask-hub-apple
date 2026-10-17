import AskHubKit
import Foundation

/// 人間がループへの指示を書く場所。ループが止まった後（最終 PR のマージ待ち）に付いた指示でループを再開する
struct InstructionPlace: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// 仮決め一覧（`decision-log` の Issue）
        case decisionLog
        /// epic の最終 PR（`epic-final` の PR）のコメント
        case finalPullRequest

        /// ログに出す名前。続く助詞の前に空白が要るものは、空白まで含める（「最終 PR に」）
        var name: String {
            switch self {
            case .decisionLog:
                "仮決め一覧"

            case .finalPullRequest:
                "最終 PR "
            }
        }

        /// 起動スクリプトに渡す再開の理由
        var resumeReason: String {
            switch self {
            case .decisionLog:
                Orchestrator.decisionLogResumeReason

            case .finalPullRequest:
                Orchestrator.finalPullRequestResumeReason
            }
        }
    }

    let kind: Kind
    /// `owner/repo`
    let repository: String
    /// Issue / PR の番号（同じリポジトリの Issue と PR で番号は重ならない）
    let number: Int
    /// 指示の対象の epic ブランチ
    let branch: String
}

// 仮決め一覧・最終 PR への指示によるループの再開。ループの開始を確かめ、再び完了したら最終 PR の本文を書き直す
extension Orchestrator {
    /// 最終 PR のマージ待ち（ループは止まっている）の間に指示が付いたら、ループを再開して処理させる。
    /// `unprocessed` はコメント（古い順）と信用する author から、未処理の指示（古い順）を返す
    func resumeIfInstructed(
        at place: InstructionPlace,
        in repository: RepositoryConfig,
        statuses: inout [String: LoopStatus],
        unprocessed: ([IssueComment], TrustedAuthors) -> [IssueComment]
    ) async throws {
        let key = repository.fullName.lowercased()
        let name = "\(repository.fullName)#\(place.number) の\(place.kind.name)"
        let status = statuses[key] ?? .idle
        let pending = pendingInstructionResumes[key].flatMap { $0.place.number == place.number ? $0 : nil }
        if let pending, !confirmIfLoopStarted(pending, status: status, in: repository) {
            return
        }
        // 動いているループは自分で処理する。異常終了したループは resumeStalledLoops が再開する
        guard !status.processAlive, status.stateFileExists == false, !status.stalled else {
            return
        }
        let comments = try await github.comments(in: place.repository, issue: place.number)
        let instructions = unprocessed(comments, trust.authors(for: place.repository))
        let attempts = pending.map { settleUnconfirmedResume($0, instructions: instructions, in: repository) } ?? 0
        guard let latest = instructions.last else {
            return
        }
        // ループが返信せずに終えても、同じコメントでは 1 回しか再開しない
        let commentKey = "\(key)#\(latest.id)"
        guard !resumedInstructionComments.contains(commentKey) else {
            return
        }
        switch await controlWorktreeAcceptance(of: place, name: name, in: repository) {
        case .accepted:
            break

        case .rejected:
            pendingInstructionResumes[key] = nil
            resumedInstructionComments.insert(commentKey)
            return

        case .undecided:
            // 処理済みにはせず、次のポーリングで確かめ直す
            return
        }
        do {
            // 再開では Discussion を伴わないので `{discussion}` は空になる。
            // epic のタスクがすべて完了していても起動するよう、起動スクリプトに再開の理由を渡す
            try await runtime.launch(
                config.loopCommand.render(for: repository),
                environment: loopEnvironment(for: repository)
                    .merging([Self.resumeReasonVariable: place.kind.resumeReason]) { _, new in new },
                for: repository
            )
        } catch {
            log("\(repository.fullName) のループを\(place.kind.name)の指示で再開できませんでした（次のポーリングで再試行します）: \(error)")
            return
        }
        // ループの開始を確かめてから、処理済みとして覚え、最終 PR の書き直しの対象にする
        pendingInstructionResumes[key] = InstructionResume(
            place: place,
            commentID: latest.id,
            commentKey: commentKey,
            epicKey: "\(key) \(place.branch)",
            attempts: attempts + 1
        )
        statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
        log("\(name)に指示が付いたので、ループを再開しました")
    }

    /// 制御用 worktree が指示の epic にあり、それが自動ループの epic か。再開しないときは理由をログに出す
    private func controlWorktreeAcceptance(
        of place: InstructionPlace,
        name: String,
        in repository: RepositoryConfig
    ) async -> ControlWorktreeAcceptance {
        let key = repository.fullName.lowercased()
        let snapshot = await runtime.epicSnapshot(of: repository)
        guard snapshot.branch == place.branch else {
            log("\(name)に指示が付きましたが、制御用 worktree が \(place.branch) ではないのでループを再開できません")
            return .rejected
        }
        // 手動ループの Discussion を取得できなかった回は、手動ループの epic かを決められない。
        // `automaticEpicBranches` は取得の失敗で自動ループとみなすが、再開はプロセスを起動するので、見送って次のポーリングで確かめる
        if manualLoops == nil {
            return .undecided
        }
        // 手動ループ（kit 1.3 までは、この PC の制御用 worktree を使うことがある）の epic は、担当者が再開する
        guard automaticEpicBranches(in: [key: snapshot])[key] == place.branch else {
            log("\(name)に指示が付きましたが、\(place.branch) は手動ループの epic なので再開しません（担当者が再開します）")
            return .rejected
        }
        return .accepted
    }

    /// 起動したループの開始を state ファイルで確かめる。
    /// 起動したプロセスが state ファイルを作らないまま終わっていて、続けて判断してよいときは `true`
    private func confirmIfLoopStarted(_ pending: InstructionResume, status: LoopStatus, in repository: RepositoryConfig) -> Bool {
        if status.stateFileExists == true {
            // ループが始まった。指示はループが周回の最初に読む（異常終了していれば resumeStalledLoops が再開する）
            confirmInstructionResume(pending, in: repository)
            return false
        }
        // 起動スクリプトの準備中など、まだ確かめられなければ待つ
        return !status.processAlive && status.stateFileExists == false
    }

    /// 起動したプロセスが、state ファイルを確かめる前に終わった。続けて起動するときの、これまでの起動回数を返す
    private func settleUnconfirmedResume(
        _ pending: InstructionResume,
        instructions: [IssueComment],
        in repository: RepositoryConfig
    ) -> Int {
        let name = "\(repository.fullName)#\(pending.place.number) の\(pending.place.kind.name)"
        if !instructions.contains(where: { $0.id == pending.commentID }) {
            // その間にループが指示に返信している（ポーリングの間に始まって終わった）ので、ループは動いた
            confirmInstructionResume(pending, in: repository)
            return 0
        }
        if pending.attempts >= Self.maxDecisionResumeAttempts {
            pendingInstructionResumes[repository.fullName.lowercased()] = nil
            resumedInstructionComments.insert(pending.commentKey)
            log("\(name)の指示でループの開始を \(pending.attempts) 回確かめられませんでした。"
                + "この指示では再開しません（loopCommand と起動スクリプトのログを確認してください）")
            return 0
        }
        // 起動スクリプトがループを始めずに終わった（タスクが無いと判断した・途中で失敗したなど）。最終 PR は書き直さない
        log("\(name)の指示で起動したループの開始を確かめられないまま、プロセスが終わりました"
            + "（\(pending.attempts)/\(Self.maxDecisionResumeAttempts) 回目）。再開し直します")
        return pending.attempts
    }

    /// 指示で起動したループの開始を確かめた。指示を処理済みとして覚え、ループが再び完了したら最終 PR の本文を書き直す
    private func confirmInstructionResume(_ pending: InstructionResume, in repository: RepositoryConfig) {
        pendingInstructionResumes[repository.fullName.lowercased()] = nil
        resumedInstructionComments.insert(pending.commentKey)
        finalizedEpics.remove(pending.epicKey)
        epicsToRefresh.insert(pending.epicKey)
        log("\(repository.fullName)#\(pending.place.number) の\(pending.place.kind.name)の指示で再開したループの開始を確かめました")
    }

    /// 起動スクリプトに再開の理由を伝える環境変数
    static let resumeReasonVariable = "ASKHUB_RESUME_REASON"
    /// 仮決め一覧への指示による再開。起動スクリプトは、未完了のタスクが無くてもループを起動する
    static let decisionLogResumeReason = "decision-log"
    /// 最終 PR への指示による再開。起動スクリプトは、未完了のタスクが無くてもループを起動する
    static let finalPullRequestResumeReason = "final-pr"
    /// 指示で、ループの開始を確かめられないまま起動を試す回数の上限（仮決め一覧・最終 PR で共通）
    static let maxDecisionResumeAttempts = 3
}

/// 制御用 worktree で、指示による再開を受け付けるか
enum ControlWorktreeAcceptance: Sendable, Equatable {
    case accepted
    /// 別の epic・手動ループの epic。この指示では再開しない
    case rejected
    /// 手動ループの Discussion を取得できず、決められない。次のポーリングで確かめ直す
    case undecided
}

/// 仮決め一覧・最終 PR への指示で起動し、開始をまだ確かめていないループ
struct InstructionResume: Sendable, Equatable {
    /// 指示の場所
    let place: InstructionPlace
    /// 再開のきっかけになったコメントの id
    let commentID: Int
    /// `resumedInstructionComments` のキー（`<repo小文字>#<コメント id>`）
    let commentKey: String
    /// `epicsToRefresh` / `finalizedEpics` のキー（`<repo小文字> <branch>`）
    let epicKey: String
    /// 起動した回数
    let attempts: Int
}
