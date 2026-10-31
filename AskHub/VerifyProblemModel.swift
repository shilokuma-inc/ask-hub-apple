import AskHubKit
import Foundation
import Observation

/// 実機確認の詳細画面の「問題あり」。再修正の依頼を作り、続けて実機確認 Issue にコメントする
/// （`docs/protocol.md` の「実機確認で問題があったとき（アプリからの「問題あり」）」。Issue #483）
@MainActor
@Observable
final class VerifyProblemModel {
    let issue: InboxIssue
    /// 問題の内容（何をしたら・どうなったか）。依頼を作った後は変えさせない（コメントを依頼の本文とそろえるため）
    var description = ""
    /// 添付するファイル（選んだ順）。送るまで GitHub に上げず、メモリにだけ持つ。依頼を作った後は変えさせない
    var attachments: [AttachmentFile] = []
    /// 選んだのに足さなかったファイルの説明（上限・読めないなど）。添付欄とドロップの受け口が書く（`AttachmentAdder`）
    var attachmentNotices: [String] = []
    private(set) var isSending = false
    private(set) var errorMessage: String?
    /// 作った再修正の依頼。コメントだけ失敗したときは、これを使ってコメントだけを再試行する（依頼を重ねない）
    private(set) var createdRequest: CreatedIssue?
    /// 依頼を作ったときの内容。コメントの再試行でも同じ内容を投稿する
    private var sentProblem: VerifyProblem?
    /// 依頼とコメントの両方を送り終えた
    private(set) var isCompleted = false

    private let tokenStore: any TokenStore
    private let makeRequester: @Sendable (String) -> any IdeaRequesting
    private let makeCommenter: @Sendable (String) -> any VerifyProblemCommenting
    private let makeUploader: @Sendable (String) -> any AttachmentUploading

    init(
        issue: InboxIssue,
        tokenStore: any TokenStore,
        makeRequester: @escaping @Sendable (String) -> any IdeaRequesting,
        makeCommenter: @escaping @Sendable (String) -> any VerifyProblemCommenting,
        makeUploader: @escaping @Sendable (String) -> any AttachmentUploading = {
            GitHubAttachmentUploader(client: GitHubClient(token: $0))
        }
    ) {
        self.issue = issue
        self.tokenStore = tokenStore
        self.makeRequester = makeRequester
        self.makeCommenter = makeCommenter
        self.makeUploader = makeUploader
    }

    private var problem: VerifyProblem {
        sentProblem ?? VerifyProblem(issue: issue, description: description)
    }

    /// 依頼を作った後で、コメントだけが残っている
    var isRetryingComment: Bool {
        createdRequest != nil && !isCompleted
    }

    var canSend: Bool {
        !isSending && !isCompleted && problem.isValid
    }

    /// 確認ダイアログに出す、作る依頼の説明
    var confirmation: String {
        if let createdRequest, !isCompleted {
            return "再修正の依頼 #\(createdRequest.number) へのリンクを付けて、この Issue に問題の内容をコメントします。依頼は作り直しません"
        }
        let attachments = attachments.isEmpty ? "" : "添付 \(attachments.count) 件を \(issue.repository) に上げてから、"
        return "\(attachments)\(issue.repository) に「\(problem.request.title)」を依頼し、この Issue に問題の内容をコメントします。Issue は閉じません"
    }

    /// 依頼を作り（まだ作っていなければ）、実機確認 Issue にコメントする。
    /// 添付があれば、依頼を作る前に実機確認 Issue のリポジトリへすべて上げ、依頼とコメントの両方に同じ添付欄を付ける。
    /// 上げられない・依頼を作れなければ何も投稿しない。コメントだけ失敗したら、次の呼び出しではコメントだけを再試行する（上げ直さない）
    func send() async {
        guard canSend else {
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        var problem = problem
        do {
            guard let token = try tokenStore.load() else {
                throw IdeaRequestModel.MissingTokenError()
            }
            let request: CreatedIssue
            if let createdRequest {
                request = createdRequest
            } else {
                let files = attachments
                if !files.isEmpty {
                    problem.attachments = try await makeUploader(token).upload(files, to: issue.repository)
                }
                request = try await makeRequester(token).create(problem.request)
                createdRequest = request
                sentProblem = problem
            }
            _ = try await makeCommenter(token).post(problem, request: request)
            isCompleted = true
        } catch {
            errorMessage = Self.message(for: error, createdRequest: createdRequest)
        }
    }

    /// 失敗の説明。トークンの値は含めない
    static func message(for error: any Error, createdRequest: CreatedIssue?) -> String {
        // 添付を上げられなかった（Contents の書き込み権限・競合）。依頼はまだ作っていないので、そのまま説明する
        if error is AttachmentUploadError {
            return IdeaRequestModel.message(for: error)
        }
        let reason = switch error {
        // Issues の書き込み権限が無いと 403、リポジトリが見えないトークンでは 404 になる
        case GitHubError.http(status: 403, _), GitHubError.http(status: 404, _):
            "トークンに、このリポジトリの Issues の書き込み権限（Read and write）があるか確かめてください"

        case VerifyProblemError.invalidProblem, IdeaRequestError.invalidRequest:
            "問題の内容を入力してください"

        default:
            IdeaRequestModel.message(for: error)
        }
        guard let createdRequest else {
            return "送れませんでした。\(reason)"
        }
        return "再修正の依頼 #\(createdRequest.number) は作りましたが、この Issue へのコメントを投稿できませんでした。\(reason)"
    }
}

extension IdeaRequestModel {
    /// 実機確認の「問題あり」のモデル。依頼はこのモデルと同じトークン・依頼の作り方で作る（デモモードでは GitHub に書き込まない）
    func verifyProblemModel(for issue: InboxIssue) -> VerifyProblemModel {
        let model = VerifyProblemModel(
            issue: issue,
            tokenStore: tokenStore,
            makeRequester: makeRequester,
            makeCommenter: makeProblemCommenter,
            makeUploader: makeUploader
        )
        #if DEBUG
        // UI テストでは、システムのファイルピッカーを操作できないので、サンプルの添付を入れた状態から始める
        if ProcessInfo.processInfo.arguments.contains(Self.sampleAttachmentsLaunchArgument) {
            model.attachments = AttachmentFile.samples
        }
        #endif
        return model
    }
}

/// デモモード・Preview・UI テスト用。コメントしたことにして GitHub には送らない
struct SampleVerifyProblemCommenter: VerifyProblemCommenting {
    func post(_ problem: VerifyProblem, request: CreatedIssue) async throws -> URL {
        URL(string: problem.issue.url.absoluteString + "#issuecomment-1") ?? problem.issue.url
    }
}
