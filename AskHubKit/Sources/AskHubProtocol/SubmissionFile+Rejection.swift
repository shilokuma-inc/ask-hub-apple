import Foundation

// `SubmissionFile` の、審査で断られた（リジェクト）ときの対処（`docs/renewal/release.md` の「リジェクト」）。
// 人が App Store Connect で理由を見てクライアントに貼り（`reportRejection`）、常時オンの Mac の Claude が直し方の案を書き、
// 人が直し方を選ぶ（`resolveRejection`）。選んだら審査に出す中身（`submit`）を消し、人が確かめて「審査に出し直す」（`submitForReview`）

extension SubmissionFile {
    /// リジェクトの直し方
    public enum RejectionRemedy: String, Codable, Sendable, CaseIterable {
        /// コードを直す（「このリリースを直す」依頼にする。直した後に上げたビルドで出し直す）
        case code
        /// メタデータだけ直す（掲載文・What's New・App Review の情報。ビルドは作り直さない）
        case metadata
        /// 返信だけで済む（人が App Store Connect で返信を貼る）
        case reply
    }

    /// 人が貼ったリジェクトの理由（文と画像）。画像の中身は `attachments/<device>/<nonce>/<n>`
    public struct RejectionReport: Codable, Equatable, Sendable {
        public var text: String
        public var attachments: [RequestAttachment]
        public var approval: IntentReference
        public var at: Timestamp

        public init(text: String, attachments: [RequestAttachment], approval: IntentReference, at: Timestamp) {
            self.text = text
            self.attachments = attachments
            self.approval = approval
            self.at = at
        }
    }

    /// 「このリリースを直す」依頼の下書き（題と本文）
    public struct RequestDraftText: Codable, Equatable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Claude の直し方の案。どの直し方を選んでも使えるよう、書けたものはすべて持つ
    public struct RejectionTriage: Codable, Equatable, Sendable {
        /// Claude が勧める直し方（最後に選ぶのは人）
        public var remedy: RejectionRemedy
        /// 断られた理由の要約（日本語）
        public var summary: String
        /// 直し方の案（手順。App Store Connect で人がすることも書く）
        public var plan: String
        /// 「このリリースを直す」依頼の下書き（コードを直すとき）
        public var request: RequestDraftText?
        /// 掲載文の直す案。`current` は断られた版の今の文（言語ごと）。読めなかったら nil
        public var listing: Listing?
        /// What's New の直す案（変える言語だけ）
        public var whatsNew: [LocalizedText]?
        /// App Review の情報の直す案。`current` は断られた版の今の情報。読めなかったら nil
        public var appReview: AppReview?
        /// App Review への返信の下書き（審査の文と同じ言語）
        public var reply: String?
        public var draftedAt: Timestamp

        public init(
            remedy: RejectionRemedy,
            summary: String,
            plan: String,
            request: RequestDraftText? = nil,
            listing: Listing? = nil,
            whatsNew: [LocalizedText]? = nil,
            appReview: AppReview? = nil,
            reply: String? = nil,
            draftedAt: Timestamp
        ) {
            self.remedy = remedy
            self.summary = summary
            self.plan = plan
            self.request = request
            self.listing = listing
            self.whatsNew = whatsNew
            self.appReview = appReview
            self.reply = reply
            self.draftedAt = draftedAt
        }

        /// 要約・案・返信の長さの上限（Unicode のコードポイント）
        public static let summaryLimit = 1_000
        public static let planLimit = 4_000
        public static let replyLimit = 4_000
    }

    /// 人が選んだ直し方
    public struct RejectionChoice: Codable, Equatable, Sendable {
        public var remedy: RejectionRemedy
        public var approval: IntentReference
        public var at: Timestamp

        public init(remedy: RejectionRemedy, approval: IntentReference, at: Timestamp) {
            self.remedy = remedy
            self.approval = approval
            self.at = at
        }
    }

    /// 1 回の審査で断られたときの対処（断られた「審査に出す」ごとに 1 つ）
    public struct Rejection: Codable, Equatable, Sendable {
        /// 断られた「審査に出す」を受け付けた時刻（`submit.at`）。どの提出への対処かを見分ける
        public var submittedAt: Timestamp
        /// 断られたプラットフォーム（理由を受け付けたときに読んだもの）
        public var platforms: [AppStorePlatform]
        public var report: RejectionReport
        /// Claude の案。まだ書いていなければ nil
        public var triage: RejectionTriage?
        /// 案を書けなかった理由（人が貼り直すか、理由を読んで直し方を選ぶ）
        public var failure: String?
        /// 人が選んだ直し方。まだ選んでいなければ nil
        public var choice: RejectionChoice?

        public init(
            submittedAt: Timestamp,
            platforms: [AppStorePlatform],
            report: RejectionReport,
            triage: RejectionTriage? = nil,
            failure: String? = nil,
            choice: RejectionChoice? = nil
        ) {
            self.submittedAt = submittedAt
            self.platforms = platforms
            self.report = report
            self.triage = triage
            self.failure = failure
            self.choice = choice
        }

        /// 合わない点
        public var problems: [String] {
            var problems: [String] = []
            if platforms.isEmpty || Set(platforms).count != platforms.count { problems.append("rejection の platforms が空か重複している") }
            if report.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, report.attachments.isEmpty {
                problems.append("rejection の report に文も画像も無い")
            }
            if report.text.unicodeScalars.count > ReportRejectionIntent.maximumTextLength {
                problems.append("rejection の report の text が \(ReportRejectionIntent.maximumTextLength) 文字を超えている")
            }
            if let triage { problems += Self.problems(of: triage) }
            if triage != nil, failure != nil { problems.append("rejection は triage と failure を一緒に持たない") }
            if choice != nil, triage == nil, failure == nil { problems.append("rejection の choice は、案を書いた（書けなかった）後だけ持つ") }
            if let choice, choice.at < report.at { problems.append("rejection の choice が report より前") }
            return problems
        }

        private static func problems(of triage: RejectionTriage) -> [String] {
            var problems: [String] = []
            func check(_ text: String?, _ name: String, limit: Int) {
                guard let text else { return }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > limit {
                    problems.append("rejection の triage の \(name) は 1〜\(limit) 文字")
                }
            }
            check(triage.summary, "summary", limit: RejectionTriage.summaryLimit)
            check(triage.plan, "plan", limit: RejectionTriage.planLimit)
            check(triage.reply, "reply", limit: RejectionTriage.replyLimit)
            check(triage.request?.title, "request の title", limit: RequestIntent.maximumTitleLength)
            check(triage.request?.body, "request の body", limit: RequestIntent.maximumBodyLength)
            if triage.remedy == .code, triage.request == nil { problems.append("コードを直す案に request が無い") }
            if triage.remedy == .reply, triage.reply == nil { problems.append("返信だけで済む案に reply が無い") }
            if let listing = triage.listing { problems += Listing.problems(of: listing, name: "rejection の triage の listing") }
            if let whatsNew = triage.whatsNew { problems += LocalizedText.problems(of: whatsNew, name: "rejection の triage の whatsNew") }
            if let review = triage.appReview { problems += AppReview.problems(of: review, name: "rejection の triage の appReview") }
            return problems
        }
    }

    /// いちばん新しいリジェクトの対処
    public var rejection: Rejection? { rejections?.last }

    /// 審査で断られたプラットフォームがある（終わっていない版だけ）
    public var isRejected: Bool { !isEnded && review.contains { $0.state.isRejected } }

    /// 人がリジェクトの理由を貼るのを待っている（AskHub で出した版が断られ、その提出への理由をまだ受け付けていない）。
    /// 案を書いた後でも、直し方を選ぶ前なら貼り直せる（`canReportRejection`）
    public var awaitsRejectionReport: Bool {
        guard canReportRejection, let submit else { return false }
        return rejection?.submittedAt != submit.at
    }

    /// リジェクトの理由を貼れる（AskHub で出した版が断られ、その提出への直し方をまだ選んでいない）
    public var canReportRejection: Bool {
        guard origin == .askhub, isRejected, let submit, !isSubmitting else { return false }
        guard let rejection, rejection.submittedAt == submit.at else { return true }
        return rejection.choice == nil
    }

    /// 司令塔が Claude に直し方の案を書かせるのを待っている
    public var awaitsRejectionTriage: Bool {
        guard canReportRejection, let rejection, rejection.submittedAt == submit?.at else { return false }
        return rejection.triage == nil && rejection.failure == nil
    }

    /// 人が直し方を選ぶのを待っている（案を書いた・書けなかった）
    public var awaitsRejectionChoice: Bool {
        guard canReportRejection, let rejection, rejection.submittedAt == submit?.at else { return false }
        return rejection.triage != nil || rejection.failure != nil
    }

    /// コードを直すを選び、直した後に上げたビルドをまだ見つけていない（出し直す準備はそろわない）
    public var awaitsFixedBuild: Bool {
        guard !isEnded, submit == nil, let choice = rejection?.choice, choice.remedy == .code else { return false }
        return !builds.contains { build in build.uploadedAt.map { $0 > choice.at } ?? false }
    }
}
