import AskHubKit
import Foundation

/// 質問への回答の添付（Discussion #669 の Q6）
extension InboxModel {
    /// 添付を質問のあるリポジトリ（Discussion / PR のリポジトリ）に上げてから、添付欄を付けた回答を投稿する。
    /// 上げられなければ回答を投稿しない（もう一度投稿すると上げ直す）
    func post(_ answer: Answer, attachments files: [AttachmentFile], to question: InboxQuestion) async throws {
        var answer = answer
        if !files.isEmpty {
            guard let token = try tokenStore.load() else {
                throw MissingTokenError()
            }
            let repository = question.subject.repository
            answer.attachments = try await makeUploader(token).upload(files, to: repository)
            answer.attachmentRepository = repository
        }
        try await post(answer, to: question)
    }
}

/// 添付を上げられなかったときの説明（依頼・回答・「問題あり」で共通）。トークンの値は含めない
enum AttachmentUploadMessage {
    static func message(for error: any Error) -> String? {
        switch error {
        // 依頼先に書き込めないトークン。依頼・回答はまだ投稿していない
        case AttachmentUploadError.missingContentsPermission:
            "添付を上げられませんでした。トークンに、依頼先のリポジトリの Contents の書き込み権限（Read and write）があるか確かめてください"

        case AttachmentUploadError.conflict:
            "添付を上げられませんでした。少し待ってから、もう一度送ってください"

        default:
            nil
        }
    }
}
