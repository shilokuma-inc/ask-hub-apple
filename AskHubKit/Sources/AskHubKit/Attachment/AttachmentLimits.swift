import Foundation

/// 添付の上限と、選んだファイルを一覧に足してよいかの確認（`docs/protocol.md` の「添付ファイル」の「種類と上限」）
public enum AttachmentLimits {
    /// 1 ファイルの上限（10 MB。1 MB = 1,048,576 バイト）
    public static let maxFileSize = 10 * 1_024 * 1_024
    /// 1 回の送信で添付できる数
    public static let maxCount = 10

    /// 一覧に足さなかったファイルと、その理由
    public enum Rejection: Sendable, Equatable {
        /// 1 ファイルの上限を超えている
        case tooLarge(name: String)
        /// 一覧が上限の数に達している
        case tooMany(name: String)
        /// テキストの種類なのに UTF-8 で読めない
        case notUTF8Text(name: String)
        /// 中身が空
        case empty(name: String)

        public var name: String {
            switch self {
            case let .tooLarge(name), let .tooMany(name), let .notUTF8Text(name), let .empty(name):
                name
            }
        }

        /// 画面に出す説明
        public var message: String {
            switch self {
            case let .tooLarge(name):
                "\(name) は \(AttachmentSize.displayText(bytes: AttachmentLimits.maxFileSize)) を超えるため添付できません"

            case let .tooMany(name):
                "添付は \(AttachmentLimits.maxCount) ファイルまでです（\(name) は足していません）"

            case let .notUTF8Text(name):
                "\(name) は UTF-8 のテキストとして読めないため添付できません"

            case let .empty(name):
                "\(name) は中身が空のため添付できません"
            }
        }
    }

    /// `current` の後ろに `files` を選んだ順に足す。上限を超えるもの・読めないテキストは足さずに理由を返す
    public static func adding(
        _ files: [AttachmentFile],
        to current: [AttachmentFile]
    ) -> (attachments: [AttachmentFile], rejections: [Rejection]) {
        var attachments = current
        var rejections: [Rejection] = []
        for file in files {
            if file.data.isEmpty {
                rejections.append(.empty(name: file.name))
            } else if file.data.count > maxFileSize {
                rejections.append(.tooLarge(name: file.name))
            } else if AttachmentKind(mimeType: file.type) == .text, String(bytes: file.data, encoding: .utf8) == nil {
                rejections.append(.notUTF8Text(name: file.name))
            } else if attachments.count >= maxCount {
                rejections.append(.tooMany(name: file.name))
            } else {
                attachments.append(file)
            }
        }
        return (attachments, rejections)
    }
}
