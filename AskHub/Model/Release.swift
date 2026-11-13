import Foundation

/// App Store で配信した版と、その後作業の進み具合（状態リポジトリの `releases/<版>.json`）。画面用のモデル
struct Release: Identifiable, Hashable {
    /// `<リポジトリの id>/<版>`
    var id: String { Self.id(repositoryID, version) }
    var repositoryID: TargetRepository.ID
    /// 版の番号（`1.1.0`）
    var version: String
    /// 配信したプラットフォーム（見つけた順）
    var platforms: [Platform]
    var detectedAt: Date
    var updatedAt: Date
    /// 配信したコミット。まだ求めていなければ nil
    var commit: Commit?
    /// 配信したコミットに付けたタグ（`v1.1.0`）
    var tagName: String?
    var notes: Notes?
    /// 公開した GitHub Release の画面
    var githubReleaseURL: URL?
    /// develop の版を次に上げる PR
    var nextVersion: NextVersion?
    /// 後作業を進められなかった理由（進められたら消える）
    var problem: Problem?
    /// この端末から送った公開の様子
    var publish: PublishState = .none

    struct Platform: Hashable {
        /// `iOS`・`macOS` など
        var name: String
        /// ビルドの番号
        var build: String
    }

    struct Commit: Hashable {
        var sha: String
        /// 人が手で付けたタグから求めたか（でなければ、ビルドを上げた Upload の実行から）
        var fromExistingTag: Bool

        var shortSHA: String { String(sha.prefix(7)) }
    }

    struct Notes: Hashable {
        /// 下書きの版（公開の意図の対象の版）
        var version: Int
        /// 変更を数え始めたタグ。初めての配信なら nil
        var previousTag: String?
        /// Claude の下書き（Markdown）
        var draft: String
        /// 人が確かめて公開を押した本文。押す前は nil
        var confirmed: String?
    }

    /// 次の版の PR の様子
    enum NextVersionState: Hashable {
        /// PR を開いて、チェックを待っている
        case open
        case merged
        /// develop の版がもう大きいので、上げなかった
        case skipped
    }

    struct NextVersion: Hashable {
        var version: String
        var state: NextVersionState
        var pullRequest: Int?
    }

    /// 後作業の段取り（司令塔の `ReleaseFile.Step` と同じ）
    enum Step: Hashable, CaseIterable {
        case commit
        case tag
        case notes
        case githubRelease
        case nextVersion

        var label: String {
            switch self {
            case .commit: "配信したコミット"
            case .tag: "タグ"
            case .notes: "リリース文"
            case .githubRelease: "GitHub Release"
            case .nextVersion: "次の版"
            }
        }
    }

    struct Problem: Hashable {
        var step: Step
        var message: String
        /// やり直しても進まないので、人が直す
        var needsHuman: Bool
        var at: Date
    }

    enum PublishState: Hashable {
        case none
        /// 公開を送り、司令塔が受け付けるのを待っている
        case sending
        /// 送った公開を、司令塔が断った
        case rejected(String)
    }

    /// 人がリリース文を確かめて公開を押すのを待っている（「あなたの番」に出す）
    var awaitsNotesReview: Bool {
        githubReleaseURL == nil && notes != nil && notes?.confirmed == nil && publish != .sending
    }

    /// 人が直すまで進まない後作業がある
    var needsHuman: Bool { problem?.needsHuman == true }

    /// 後作業がすべて終わった（タグ・GitHub Release・次の版）
    var isFinished: Bool {
        tagName != nil && githubReleaseURL != nil && (nextVersion?.state == .merged || nextVersion?.state == .skipped)
    }

    static func id(_ repositoryID: TargetRepository.ID, _ version: String) -> ID {
        "\(repositoryID)/\(version)"
    }

    /// 例: iOS (31)・macOS (32)
    var platformSummary: String {
        platforms.map { "\($0.name) (\($0.build))" }.joined(separator: "・")
    }
}

// MARK: - 段取りの様子

extension Release {
    /// 段取りの様子
    enum StepState: Hashable {
        case done
        /// 司令塔が進めている・待っている（人は何もしなくてよい）
        case working
        /// 人の番
        case waitingHuman
        /// 進められない（人が直す）
        case problem
    }

    /// 1 つの段取りの様子（詳細の画面に並べる）
    struct StepStatus: Identifiable, Hashable {
        var step: Step
        var title: String
        var detail: String
        var state: StepState

        var id: Step { step }
    }

    /// 段取りの並び（配信したコミット → タグ → リリース文 → GitHub Release → 次の版）
    var steps: [StepStatus] {
        [commitStatus, tagStatus, notesStatus, releaseStatus, nextVersionStatus]
    }

    /// 段取りに人が直す・待っている問題があれば、その文
    private func problemStatus(_ step: Step, title: String) -> StepStatus? {
        guard let problem, problem.step == step || (step == .githubRelease && problem.step == .notes) else {
            return nil
        }
        return StepStatus(step: step, title: title, detail: problem.message, state: problem.needsHuman ? .problem : .working)
    }

    private var commitStatus: StepStatus {
        let title = Step.commit.label
        if let commit {
            let source = commit.fromExistingTag ? "前からあったタグ" : "ビルドを上げた Upload の実行"
            return StepStatus(step: .commit, title: title, detail: "\(commit.shortSHA)（\(source)から）", state: .done)
        }
        return problemStatus(.commit, title: title)
            ?? StepStatus(step: .commit, title: title, detail: "ビルドを上げた Upload の実行を探しています", state: .working)
    }

    private var tagStatus: StepStatus {
        let title = Step.tag.label
        if let tagName {
            return StepStatus(step: .tag, title: title, detail: tagName, state: .done)
        }
        return problemStatus(.tag, title: title)
            ?? StepStatus(step: .tag, title: title, detail: commit == nil ? "コミットが決まってから付けます" : "付けています", state: .working)
    }

    private var notesStatus: StepStatus {
        let title = Step.notes.label
        if notes?.confirmed != nil || githubReleaseURL != nil {
            return StepStatus(step: .notes, title: title, detail: "確かめました", state: .done)
        }
        if case .rejected(let reason) = publish {
            return StepStatus(step: .notes, title: title, detail: "公開を受け付けませんでした: \(reason)", state: .waitingHuman)
        }
        if publish == .sending {
            return StepStatus(step: .notes, title: title, detail: "公開を送りました。受け付けるのを待っています", state: .working)
        }
        if notes != nil {
            return StepStatus(step: .notes, title: title, detail: "下書きを確かめて、公開してください", state: .waitingHuman)
        }
        return problemStatus(.githubRelease, title: title)
            ?? StepStatus(step: .notes, title: title, detail: tagName == nil ? "タグを付けてから下書きします" : "下書きしています", state: .working)
    }

    private var releaseStatus: StepStatus {
        let title = Step.githubRelease.label
        if githubReleaseURL != nil, let tagName {
            return StepStatus(step: .githubRelease, title: title, detail: "\(tagName) を公開しました", state: .done)
        }
        if notes?.confirmed != nil {
            return StepStatus(step: .githubRelease, title: title, detail: "公開しています（10 分ほどで出ます）", state: .working)
        }
        return StepStatus(step: .githubRelease, title: title, detail: "リリース文を確かめてから公開します", state: .working)
    }

    private var nextVersionStatus: StepStatus {
        let title = Step.nextVersion.label
        if let problem = problemStatus(.nextVersion, title: title) {
            return problem
        }
        guard let nextVersion else {
            return StepStatus(step: .nextVersion, title: title, detail: "develop の版を確かめています", state: .working)
        }
        switch nextVersion.state {
        case .open:
            let pull = nextVersion.pullRequest.map { "PR #\($0) の" } ?? ""
            return StepStatus(step: .nextVersion, title: title, detail: "\(nextVersion.version) に上げる\(pull)チェックを待っています", state: .working)
        case .merged:
            return StepStatus(step: .nextVersion, title: title, detail: "develop を \(nextVersion.version) に上げました", state: .done)
        case .skipped:
            return StepStatus(step: .nextVersion, title: title, detail: "develop はもう \(nextVersion.version) です", state: .done)
        }
    }
}
