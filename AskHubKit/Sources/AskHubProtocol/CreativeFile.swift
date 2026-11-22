import Foundation

/// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の案と反映（`repos/<owner>/<repo>/creative.json`。書き手は司令塔）。
/// 人が案を頼む（`draftCreativeAssets`）と、Claude が案（`CreativeSpec`）を書き、司令塔が書き出しのワークフローで画像にして、人が確かめる。
/// 人が承認（`approveCreativeAssets`）した案は、次のリリースの「審査に出す」で版の言語に置く（`docs/renewal/creative-assets.md`）
public struct CreativeFile: StateFile {
    public static let formatVersion = 1
    /// 残す見比べの案の数（前の案）
    public static let previousLimit = 1

    public var repo: RepositoryFullName
    /// 今の案（人が確かめる番か、作っている途中）。まだ頼まれていなければ nil
    public var draft: Draft?
    /// 前の案（今の案と見比べるため）。無ければ nil
    public var previous: Rendition?
    /// 人が承認した案（次のリリースで置く）。無ければ nil
    public var approved: Approval?
    /// 配信中の版に置かれている画像（今の App Store）。読めていなければ nil
    public var live: Live?
    /// 審査に出すときに置いた記録（新しい順。10 件まで）
    public var placed: [Placement]
    /// 進められなかった理由（案の頼みと関係なく、ワークフローが無いなど。人が直す）
    public var problem: String?
    public var updatedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        draft: Draft? = nil,
        previous: Rendition? = nil,
        approved: Approval? = nil,
        live: Live? = nil,
        placed: [Placement] = [],
        problem: String? = nil,
        updatedAt: Timestamp
    ) {
        self.repo = repo
        self.draft = draft
        self.previous = previous
        self.approved = approved
        self.live = live
        self.placed = placed
        self.problem = problem
        self.updatedAt = updatedAt
    }

    /// 案の進み具合
    public enum DraftState: String, Codable, Sendable {
        /// Claude が案を書いている
        case drafting
        /// GitHub Actions で書き出している
        case rendering
        /// 書き出した（人が確かめる番）
        case rendered
        /// 案か書き出しに失敗した（`failure` に理由。人は直してほしいことを書いてやり直せる）
        case failed
    }

    /// 人が案を頼んだ・直してほしいと書いた
    public struct Request: Codable, Equatable, Sendable {
        public var approval: IntentReference
        /// 直してほしいこと（最初の案なら nil）
        public var comment: String?
        public var at: Timestamp

        public init(approval: IntentReference, comment: String? = nil, at: Timestamp) {
            self.approval = approval
            self.comment = comment
            self.at = at
        }
    }

    /// 書き出した 1 枚
    public struct Image: Codable, Equatable, Sendable {
        /// App Store Connect の言語
        public var locale: String
        public var kind: CreativeKind
        /// 元の画像（常時オンの Mac に置く）の MD5（16 進 32 文字）
        public var md5: String
        /// 見本（幅 600 の JPEG を base64 にした文字）の状態リポジトリのパス（`StatePath.creativePreview`）
        public var preview: String
        /// 書き出しを止めない問題（はみ出し・安全領域の外の文字・無い画面など。app-kit の `report.json` の言語・種類ごとの `problems`）
        public var problems: [CreativeProblem]

        public init(locale: String, kind: CreativeKind, md5: String, preview: String, problems: [CreativeProblem] = []) {
            self.locale = locale
            self.kind = kind
            self.md5 = md5
            self.preview = preview
            self.problems = problems
        }

        var violations: [String] {
            var problems = self.problems.flatMap(\.problems)
            if !LocalizedText.isLocale(locale) { problems.append("画像の locale は App Store Connect の言語") }
            if md5.wholeMatch(of: #/[0-9a-f]{32}/#) == nil { problems.append("画像の md5 は 16 進 32 文字") }
            if !StatePath.isCreativePreviewPath(preview) { problems.append("画像の preview はクリエイティブの見本のパス") }
            return problems
        }
    }

    /// 今の案
    public struct Draft: Codable, Equatable, Sendable {
        /// 案の版（1 から。頼まれるたびに上げる）。人の意図の `targetVersion`
        public var revision: Int
        public var request: Request
        public var state: DraftState
        /// Claude が書いた案（書いている間は nil）
        public var spec: CreativeSpec?
        /// Claude の案の説明（人に見せる）
        public var reason: String?
        public var draftedAt: Timestamp?
        /// 書き出しのワークフローの実行（`app-store-creative.yml`）
        public var run: WorkflowRunRecord?
        /// 6.9 inch の画面を撮った実行の id（次の案で使い回す。撮った実行の artifact が消えていれば撮り直す）
        public var screenshotsRun: Int?
        /// 書き出した画像（言語 × 種類）。書き出す前は空
        public var images: [Image]
        /// 案ぜんたいの書き出しを止めない問題（Apple の決まりに合わない文言・低いコントラスト）
        public var problems: [CreativeProblem]
        /// 失敗した理由（`failed` のとき）
        public var failure: String?

        public init(
            revision: Int,
            request: Request,
            state: DraftState,
            spec: CreativeSpec? = nil,
            reason: String? = nil,
            draftedAt: Timestamp? = nil,
            run: WorkflowRunRecord? = nil,
            screenshotsRun: Int? = nil,
            images: [Image] = [],
            problems: [CreativeProblem] = [],
            failure: String? = nil
        ) {
            self.revision = revision
            self.request = request
            self.state = state
            self.spec = spec
            self.reason = reason
            self.draftedAt = draftedAt
            self.run = run
            self.screenshotsRun = screenshotsRun
            self.images = images
            self.problems = problems
            self.failure = failure
        }

        /// 人が確かめる番（書き出しが終わった）
        public var awaitsReview: Bool { state == .rendered && spec != nil && !images.isEmpty }

        var violations: [String] {
            var problems: [String] = []
            if revision < 1 { problems.append("draft の revision は 1 以上") }
            if let comment = request.comment, comment.isEmpty || comment.unicodeScalars.count > CreativeIntents.commentLimit {
                problems.append("draft の request の comment は 1〜\(CreativeIntents.commentLimit) 文字")
            }
            if let spec { problems += spec.violations.map { "draft の spec: \($0)" } }
            if let reason, reason.isEmpty || reason.unicodeScalars.count > 2000 { problems.append("draft の reason は 1〜2000 文字") }
            if let failure, failure.isEmpty || failure.unicodeScalars.count > 1000 { problems.append("draft の failure は 1〜1000 文字") }
            if state == .failed, failure == nil { problems.append("failed の draft は failure を持つ") }
            if [.rendering, .rendered].contains(state), spec == nil { problems.append("\(state.rawValue) の draft は spec を持つ") }
            if state == .rendered, images.isEmpty { problems.append("rendered の draft は images を持つ") }
            if let screenshotsRun, screenshotsRun <= 0 { problems.append("draft の screenshotsRun は 1 以上") }
            problems += run?.problems(label: "draft の run") ?? []
            problems += images.flatMap(\.violations)
            problems += self.problems.flatMap(\.problems)
            return problems
        }
    }

    /// 前の案（見比べるため。書き出しまで終わったもの）
    public struct Rendition: Codable, Equatable, Sendable {
        public var revision: Int
        public var spec: CreativeSpec
        public var images: [Image]

        public init(revision: Int, spec: CreativeSpec, images: [Image]) {
            self.revision = revision
            self.spec = spec
            self.images = images
        }
    }

    /// 人が承認した案
    public struct Approval: Codable, Equatable, Sendable {
        public var revision: Int
        public var spec: CreativeSpec
        public var images: [Image]
        public var approval: IntentReference
        public var at: Timestamp
        /// App Store Connect のライブラリに上げた様子（上げる前は nil）
        public var library: Library?

        public init(revision: Int, spec: CreativeSpec, images: [Image], approval: IntentReference, at: Timestamp, library: Library? = nil) {
            self.revision = revision
            self.spec = spec
            self.images = images
            self.approval = approval
            self.at = at
            self.library = library
        }
    }

    /// 承認した画像を、App Store Connect のライブラリに上げた様子（配置はしない。審査に出すときに置く）
    public struct Library: Codable, Equatable, Sendable {
        /// 上げる画像の数（同じ画像は 1 つ）
        public var total: Int
        /// 置ける状態になった数
        public var ready: Int
        /// 上げ始めた時刻
        public var sentAt: Timestamp

        public init(total: Int, ready: Int, sentAt: Timestamp) {
            self.total = total
            self.ready = ready
            self.sentAt = sentAt
        }
    }

    /// 配信中の版に置かれている画像（今の App Store）
    public struct Live: Codable, Equatable, Sendable {
        /// 読んだ配信中の版。配信中の版が無ければ nil
        public var version: MarketingVersion?
        public var images: [LiveImage]
        public var readAt: Timestamp

        public init(version: MarketingVersion? = nil, images: [LiveImage] = [], readAt: Timestamp) {
            self.version = version
            self.images = images
            self.readAt = readAt
        }
    }

    public struct LiveImage: Codable, Equatable, Sendable {
        public var locale: String
        public var kind: CreativeKind
        /// App Store Connect の画像の URL（CDN の元の大きさ）
        public var url: String

        public init(locale: String, kind: CreativeKind, url: String) {
            self.locale = locale
            self.kind = kind
            self.url = url
        }
    }

    /// 審査に出すときに置いた記録
    public struct Placement: Codable, Equatable, Sendable {
        public var version: MarketingVersion
        /// 置いた案の版
        public var revision: Int
        public var at: Timestamp

        public init(version: MarketingVersion, revision: Int, at: Timestamp) {
            self.version = version
            self.revision = revision
            self.at = at
        }
    }

    public var violations: [String] {
        var problems = draft?.violations ?? []
        if let previous {
            problems += previous.spec.violations.map { "previous の spec: \($0)" }
            problems += previous.images.flatMap(\.violations)
            if let draft, previous.revision >= draft.revision { problems.append("previous の revision は draft より小さい") }
        }
        if let approved {
            problems += approved.spec.violations.map { "approved の spec: \($0)" }
            problems += approved.images.flatMap(\.violations)
            if approved.images.isEmpty { problems.append("approved は images を持つ") }
            if let library = approved.library, library.total < 0 || !(0...library.total).contains(library.ready) {
                problems.append("approved の library の ready は 0〜total")
            }
        }
        if let live {
            let malformed = live.images.contains { image in
                !LocalizedText.isLocale(image.locale) || !image.url.hasPrefix("https://") || image.url.count > 2000
            }
            if malformed { problems.append("live の画像の locale・url の形が違う") }
        }
        if placed.count > 10 { problems.append("placed は 10 件まで") }
        if let problem, problem.isEmpty || problem.unicodeScalars.count > 1000 { problems.append("problem は 1〜1000 文字") }
        return problems
    }
}

/// クリエイティブアセットの人の意図に共通の決まり
public enum CreativeIntents {
    /// 直してほしいことの長さの上限
    public static let commentLimit = 2000
}
