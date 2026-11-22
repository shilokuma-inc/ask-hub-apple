import Foundation

// MARK: - リジェクト

extension Submission {
    /// リジェクトの直し方（司令塔の `SubmissionFile.RejectionRemedy` と同じ）
    enum Remedy: String, Hashable, CaseIterable {
        case code
        case metadata
        case reply

        var label: String {
            switch self {
            case .code: "コードを直す"
            case .metadata: "メタデータだけ直す"
            case .reply: "返信だけで済む"
            }
        }

        var systemImage: String {
            switch self {
            case .code: "hammer"
            case .metadata: "text.badge.checkmark"
            case .reply: "arrowshape.turn.up.left"
            }
        }
    }

    /// 1 回の審査で断られたときの対処
    struct Rejection: Hashable {
        /// 断られたプラットフォーム（`iOS` など）
        var platforms: [String]
        /// 人が貼った審査の文
        var text: String
        /// 人が貼った画像（状態リポジトリの中のパスと名前）
        var images: [RejectionImage]
        var reportedAt: Date
        /// Claude の案。まだ書いていなければ nil
        var triage: RejectionTriage?
        /// 案を書けなかった理由
        var failure: String?
        /// 人が選んだ直し方
        var choice: Remedy?
    }

    /// リジェクトの理由に貼った画像（状態リポジトリの中のパスと名前）
    struct RejectionImage: Hashable {
        var path: String
        var name: String
    }

    /// リジェクトの直し方の Claude の案
    struct RejectionTriage: Hashable {
        /// Claude が勧める直し方
        var remedy: Remedy
        var summary: String
        var plan: String
        /// 「このリリースを直す」依頼の下書き（題と本文）
        var requestTitle: String?
        var requestBody: String?
        /// App Review への返信の下書き
        var reply: String?
        /// メタデータを直す案がある欄（例: 説明文（ja）・What's New（en-US））
        var metadataChanges: [String]
    }
}
