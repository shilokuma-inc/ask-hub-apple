import Foundation

/// GitHub Actions のワークフローの run。最終 PR の epic ブランチを TestFlight に上げたとき（`upload.yml`。Discussion #449 の Q4）や、
/// リリースのワークフロー（`release-prepare.yml` など。Discussion #605）を起動したときの状態を出すために使う
public struct WorkflowRun: Sendable, Equatable, Hashable, Identifiable {
    /// GitHub の `status`。知らない値は `other`
    public enum Status: Sendable, Equatable, Hashable {
        case queued
        case inProgress
        case completed
        /// `waiting`・`requested`・`pending` など、まだ完了していないその他の状態
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "queued":
                self = .queued

            case "in_progress":
                self = .inProgress

            case "completed":
                self = .completed

            default:
                self = .other(rawValue)
            }
        }
    }

    /// GitHub の `conclusion`（`status` が `completed` のときだけ入る）。知らない値は `other`
    public enum Conclusion: Sendable, Equatable, Hashable {
        case success
        case failure
        case cancelled
        /// `skipped`・`timed_out`・`action_required`・`startup_failure` など
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "success":
                self = .success

            case "failure":
                self = .failure

            case "cancelled":
                self = .cancelled

            default:
                self = .other(rawValue)
            }
        }
    }

    /// run の id
    public var id: Int
    /// `owner/repo`
    public var repository: String
    /// 実行したブランチ（`head_branch`）
    public var branch: String
    /// ビルドしたコミット（`head_sha`）。PR の最新の head と同じかを見るために使う
    public var headSHA: String
    public var status: Status
    public var conclusion: Conclusion?
    /// 起動のきっかけ（`workflow_dispatch` / `push` など）
    public var event: String
    /// 開始時刻（`run_started_at`。無ければ `created_at`）
    public var startedAt: Date
    /// GitHub の run ページ
    public var url: URL

    public init(
        id: Int,
        repository: String,
        branch: String,
        headSHA: String,
        status: Status,
        conclusion: Conclusion?,
        event: String,
        startedAt: Date,
        url: URL
    ) {
        self.id = id
        self.repository = repository
        self.branch = branch
        self.headSHA = headSHA
        self.status = status
        self.conclusion = conclusion
        self.event = event
        self.startedAt = startedAt
        self.url = url
    }

    /// まだ終わっていないか（queued / in_progress / waiting など）。実行中はもう一度起動しない
    public var isRunning: Bool {
        status != .completed
    }

    /// 成功して終わったか
    public var isSuccessful: Bool {
        status == .completed && conclusion == .success
    }

    /// ビルドしたコミットが、PR の最新の head と同じか
    public func builtHead(_ sha: String) -> Bool {
        headSHA.caseInsensitiveCompare(sha) == .orderedSame
    }
}

/// ワークフローの直近の run の問い合わせの結果
public enum LatestWorkflowRun: Sendable, Equatable, Hashable {
    /// ワークフローがリポジトリに無い（404）。トークンからリポジトリが見えない・Actions が無効のときも 404 になる。
    /// いずれもボタンを出さない
    case unsupported
    /// ワークフローはあるが、このブランチの run がまだ無い
    /// （`Optional<LatestWorkflowRun>` で未取得を表したときに `.none` と紛れないよう、`noRuns` と呼ぶ）
    case noRuns
    /// 直近の run
    case run(WorkflowRun)

    /// 直近の run（無ければ `nil`）
    public var run: WorkflowRun? {
        if case .run(let run) = self {
            return run
        }
        return nil
    }
}

/// ワークフローの操作で起きるエラー。`GitHubError` の HTTP の状態から、アプリで表示を分けるものを区別する
public enum WorkflowError: Error, Equatable, Sendable {
    /// トークンに Actions の権限が無い。run の取得は Actions の Read で足りるが、起動（dispatch）を含めて
    /// Fine-grained PAT の Actions: Read and write を求める（Discussion #449）。
    /// レート制限の 403（`x-ratelimit-remaining: 0`・`Retry-After`）は `GitHubError.rateLimited` のままで、ここには来ない
    case permissionDenied
    /// ワークフローがリポジトリに無い（起動が 404）。トークンからリポジトリが見えない・Actions が無効のときも 404 になる。
    /// 直近の run の取得では `LatestWorkflowRun.unsupported` で返す
    case workflowNotFound
    /// 起動が 422 で断られた。多くは `workflow_dispatch` に対応していない（以後ボタンを出さない）が、
    /// 対応しているかは既定ブランチではなく指定した `ref` 側のファイルで判定される（`workflow_dispatch` を足す前に切った epic では 422 になる）ほか、
    /// `ref` が無いとき（`No ref found for: …`）にも返る。`message` は GitHub の説明で、アプリが表示に使う
    case dispatchNotSupported(message: String?)
}

/// `upload.yml` 用に付けていた名前。`WorkflowRun` と同じ
public typealias UploadWorkflowRun = WorkflowRun
/// `upload.yml` 用に付けていた名前。`LatestWorkflowRun` と同じ
public typealias LatestUploadRun = LatestWorkflowRun
/// `upload.yml` 用に付けていた名前。`WorkflowError` と同じ
public typealias UploadWorkflowError = WorkflowError
