import Foundation

/// リリースを始めた版の準備と審査（状態リポジトリの `submissions/<版>.json`）。画面用のモデル
struct Submission: Identifiable, Hashable {
    /// `<リポジトリの id>/<版>`
    var id: String { Self.id(repositoryID, version) }
    var repositoryID: TargetRepository.ID
    /// 版の番号（`1.4.0`）
    var version: String
    /// AskHub の「リリースを始める」から進めた版か（false なら、App Store Connect で手で審査に出したのを見つけた版）
    var startedInAskHub: Bool
    /// release ブランチ（`release/1.4.0`）。まだ作っていなければ nil
    var branch: String?
    /// develop の版を次に上げる PR
    var nextVersion: Release.NextVersion?
    /// release ブランチから上げたビルド
    var builds: [Build] = []
    /// What's New の下書き。nil ならまだ下書きしていない、空なら初めての版（What's New を持たない）
    var drafts: [Localized]?
    /// ビルドか What's New の下書きが変わるたびに上がる（審査に出すときに、見たものに結びつける）
    var revision: Int
    /// 審査に出した中身。出していなければ nil
    var submitted: Submitted?
    /// プラットフォームごとの審査の状態
    var review: [Review] = []
    var distribution: RequestState = .none
    var withdrawal: RequestState = .none
    var end: EndReason?
    var problem: Problem?
    var createdAt: Date
    var updatedAt: Date
    /// 人が What's New とビルドを確かめて「審査に出す」を押すのを待っている
    var awaitsSubmission = false
    /// 審査に通り、人が「配信する」を押すのを待っている（配信の方式が手動）
    var awaitsDistribution = false
    var canWithdraw = false
    var canAbandon = false
    /// 審査に出すのを受け付けて、司令塔が App Store Connect に出し終えていない
    var isSubmitting = false
    /// この端末から送り、司令塔がまだ処理していない操作
    var sending: Action?
    /// この端末から送った操作を、司令塔が最後に断った理由
    var rejected: String?

    static func id(_ repositoryID: TargetRepository.ID, _ version: String) -> ID {
        "\(repositoryID)/\(version)"
    }

    /// 版の番号の形（0 以上の整数を `.` で 1〜3 個つないだもの。先頭の 0 なし・4 桁まで。司令塔の `MarketingVersion` と同じ）
    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { part in
            let digits = part.allSatisfy { $0.isASCII && $0.isNumber }
            return (1...4).contains(part.count) && digits && (part.count == 1 || part.first != "0")
        }
    }

    struct Build: Hashable, Identifiable {
        /// `iOS`・`macOS` など
        var platform: String
        var build: String

        var id: String { platform }
    }

    struct Localized: Hashable, Identifiable {
        /// App Store Connect の言語（`ja`・`en-US` など）
        var locale: String
        var text: String

        var id: String { locale }

        /// 例: 日本語（ja）
        var localeName: String {
            let name = Locale(identifier: "ja_JP").localizedString(forIdentifier: locale) ?? locale
            return name == locale ? locale : "\(name)（\(locale)）"
        }
    }

    /// 審査に通った後の配信の方式
    enum ReleaseType: Hashable {
        case afterApproval
        case manual
        case scheduled(Date)

        var label: String {
            switch self {
            case .afterApproval: "承認後すぐ"
            case .manual: "手動"
            case .scheduled(let date): "日時を指定（\(date.formatted(date: .abbreviated, time: .shortened))）"
            }
        }
    }

    /// 審査に出す中身（人が確かめたもの）
    struct SubmitRequest: Hashable {
        /// 見たときの準備の版
        var revision: Int
        var builds: [Build]
        var whatsNew: [Localized]
        var releaseType: ReleaseType
    }

    struct Submitted: Hashable {
        var builds: [Build]
        var whatsNew: [Localized]
        var releaseType: ReleaseType
        var at: Date
    }

    /// 審査の状態（App Store Connect の版の状態をまとめたもの）
    enum ReviewState: Hashable {
        /// 審査に出す前（版を作った・直している）
        case preparing
        case waitingForReview
        case inReview
        /// 審査に通り、配信するを押すのを待っている
        case pendingRelease
        /// 審査に通った（配信の処理中・日時を待っている）
        case approved
        case distributed
        /// 審査で断られた（リジェクト）
        case rejected
        /// 取り下げた
        case withdrawn

        var label: String {
            switch self {
            case .preparing: "審査に出す前"
            case .waitingForReview: "審査を待っています"
            case .inReview: "審査中"
            case .pendingRelease: "審査に通りました（配信を待っています）"
            case .approved: "審査に通りました"
            case .distributed: "配信しました"
            case .rejected: "審査で断られました（リジェクト）"
            case .withdrawn: "取り下げました"
            }
        }
    }

    struct Review: Hashable, Identifiable {
        var platform: String
        var state: ReviewState
        var since: Date

        var id: String { platform }
    }

    /// 人が押した操作（配信する・取り下げ）の様子
    enum RequestState: Hashable {
        case none
        /// 司令塔が受け付け、App Store Connect に送るのを待っている
        case accepted
        /// App Store Connect に送った
        case done
    }

    enum EndReason: Hashable {
        case distributed
        case abandoned
        case superseded
    }

    /// 進めることの区切り（司令塔の `SubmissionFile.Step` と同じ）
    enum Step: String, Hashable {
        case branch
        case nextVersion
        case whatsNew
        case builds
        case submit
        case distribute
        case withdraw
        case review

        var label: String {
            switch self {
            case .branch: "release ブランチ"
            case .nextVersion: "次の版"
            case .whatsNew: "What's New"
            case .builds: "ビルド"
            case .submit: "審査に出す"
            case .distribute: "配信する"
            case .withdraw: "審査の取り下げ"
            case .review: "審査の状態"
            }
        }
    }

    struct Problem: Hashable {
        var step: Step
        var message: String
        var needsHuman: Bool
        var at: Date
    }

    /// この端末から送る操作
    enum Action: Hashable {
        case start
        case submit
        case distribute
        case withdraw
        case abandon

        var label: String {
            switch self {
            case .start: "リリースを始める"
            case .submit: "審査に出す"
            case .distribute: "配信する"
            case .withdraw: "審査の取り下げ"
            case .abandon: "やめる"
            }
        }
    }

    /// 人が直すまで進まない
    var needsHuman: Bool { problem?.needsHuman == true }

    var isEnded: Bool { end != nil }

    /// 審査で断られたプラットフォームがある（対処は App Store Connect で理由を確かめてから。段階 5 の 4 で AskHub から直せるようにする）
    var isRejected: Bool { review.contains { $0.state == .rejected } }

    /// 例: iOS (45)・macOS (46)
    var buildSummary: String {
        builds.map { "\($0.platform) (\($0.build))" }.joined(separator: "・")
    }
}

// MARK: - 段取りの様子

extension Submission {
    /// 1 つの段取りの様子（詳細の画面に並べる）
    struct StepStatus: Identifiable, Hashable {
        var id: String
        var title: String
        var detail: String
        var state: Release.StepState
    }

    /// 段取りの並び。AskHub で始めた版は release ブランチから、手で出した版は審査から
    var steps: [StepStatus] {
        guard startedInAskHub else { return [reviewStatus, distributionStatus] }
        return [branchStatus, nextVersionStatus, whatsNewStatus, buildsStatus, reviewStatus, distributionStatus]
    }

    /// 一覧の行に出す、今の段取りの一言
    var summary: String {
        switch end {
        case .distributed: return "配信しました"
        case .abandoned: return "やめました"
        case .superseded: return "新しい版を配信したので終えました"
        case nil: break
        }
        if let sending { return "\(sending.label)を送りました。受け付けるのを待っています" }
        if let step = steps.first(where: { $0.state == .problem || $0.state == .waitingHuman }) {
            return "\(step.title): \(step.detail)"
        }
        return steps.last { $0.state == .done }.map { "\($0.title): \($0.detail)" } ?? "準備を始めています"
    }

    private func problemStatus(_ step: Step, id: String, title: String) -> StepStatus? {
        guard let problem, problem.step == step else { return nil }
        return StepStatus(id: id, title: title, detail: problem.message, state: problem.needsHuman ? .problem : .working)
    }

    private var branchStatus: StepStatus {
        let title = Step.branch.label
        if let branch { return StepStatus(id: "branch", title: title, detail: "\(branch) を作りました", state: .done) }
        if sending == .start {
            return StepStatus(id: "branch", title: title, detail: "リリースを始めるのを送りました", state: .working)
        }
        return problemStatus(.branch, id: "branch", title: title)
            ?? StepStatus(id: "branch", title: title, detail: "develop の先頭から作ります", state: .working)
    }

    private var nextVersionStatus: StepStatus {
        let title = Step.nextVersion.label
        if let problem = problemStatus(.nextVersion, id: "nextVersion", title: title) { return problem }
        guard let nextVersion else {
            return StepStatus(id: "nextVersion", title: title, detail: "release ブランチを作ってから、develop の版を上げます", state: .working)
        }
        switch nextVersion.state {
        case .open:
            let pull = nextVersion.pullRequest.map { "PR #\($0) の" } ?? ""
            return StepStatus(id: "nextVersion", title: title, detail: "\(nextVersion.version) に上げる\(pull)チェックを待っています", state: .working)
        case .merged:
            return StepStatus(id: "nextVersion", title: title, detail: "develop を \(nextVersion.version) に上げました", state: .done)
        case .skipped:
            return StepStatus(id: "nextVersion", title: title, detail: "develop はもう \(nextVersion.version) です", state: .done)
        }
    }

    private var whatsNewStatus: StepStatus {
        let title = Step.whatsNew.label
        if let drafts {
            let detail = drafts.isEmpty ? "初めての版なので書きません" : "下書きしました（\(drafts.map(\.locale).joined(separator: "・"))）"
            return StepStatus(id: "whatsNew", title: title, detail: detail, state: .done)
        }
        return problemStatus(.whatsNew, id: "whatsNew", title: title)
            ?? StepStatus(id: "whatsNew", title: title, detail: "前の版からの変更をもとに、言語ごとに下書きします", state: .working)
    }

    private var buildsStatus: StepStatus {
        let title = Step.builds.label
        if let problem = problemStatus(.builds, id: "builds", title: title) { return problem }
        guard !builds.isEmpty else {
            return StepStatus(id: "builds", title: title, detail: "release ブランチから上げたビルドを待っています", state: .working)
        }
        return StepStatus(id: "builds", title: title, detail: buildSummary, state: .done)
    }

    private var reviewStatus: StepStatus {
        let title = "審査"
        if let problem = problemStatus(.submit, id: "review", title: title) ?? problemStatus(.withdraw, id: "review", title: title) {
            return problem
        }
        if let rejected {
            return StepStatus(id: "review", title: title, detail: "受け付けませんでした: \(rejected)", state: .waitingHuman)
        }
        if sending == .submit || isSubmitting {
            return StepStatus(id: "review", title: title, detail: "審査に出しています", state: .working)
        }
        if sending == .withdraw || withdrawal == .accepted {
            return StepStatus(id: "review", title: title, detail: "審査を取り下げています", state: .working)
        }
        if awaitsSubmission {
            return StepStatus(id: "review", title: title, detail: "What's New とビルドを確かめて、審査に出してください", state: .waitingHuman)
        }
        if review.isEmpty {
            return StepStatus(id: "review", title: title, detail: "準備がそろったら、審査に出せます", state: .working)
        }
        let detail = review.map { "\($0.platform): \($0.state.label)" }.joined(separator: "・")
        let state: Release.StepState = if isRejected {
            .problem
        } else if review.allSatisfy({ [.pendingRelease, .approved, .distributed].contains($0.state) }) {
            .done
        } else {
            .working
        }
        return StepStatus(id: "review", title: title, detail: detail, state: state)
    }

    private var distributionStatus: StepStatus {
        let title = "配信"
        if let problem = problemStatus(.distribute, id: "distribution", title: title) { return problem }
        if end == .distributed || review.contains(where: { $0.state == .distributed }) {
            return StepStatus(id: "distribution", title: title, detail: "App Store で配信しました", state: .done)
        }
        if sending == .distribute || distribution != .none {
            return StepStatus(id: "distribution", title: title, detail: "配信しています（24 時間ほどで App Store に出ます）", state: .working)
        }
        if awaitsDistribution {
            return StepStatus(id: "distribution", title: title, detail: "審査に通りました。「配信する」を押すと配信します", state: .waitingHuman)
        }
        let detail = switch submitted?.releaseType {
        case .afterApproval?: "審査に通ったら、すぐ配信されます"
        case .manual?: "審査に通ったら、「配信する」を押して配信します"
        case .scheduled(let date)?: "審査に通ったら、\(date.formatted(date: .abbreviated, time: .shortened)) より後に配信されます"
        case nil: "審査に出すときに、配信の方式を選びます"
        }
        return StepStatus(id: "distribution", title: title, detail: detail, state: .working)
    }
}
