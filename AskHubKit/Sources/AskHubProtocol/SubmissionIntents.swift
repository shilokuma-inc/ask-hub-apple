import Foundation

// リリースを始めてから配信までの人の意図（`docs/renewal/release.md` の「リリースを始めてから配信まで」）。
// 始めた後の意図の `target` は `{type: submission, id: <版>}`。審査に出す意図だけ `targetVersion`（`submissions/<版>.json` の `revision`）を持ち、
// ほかは版の今の状態に対してだけ意味を持つので `targetVersion` を書かない

/// リリースを始めた版を対象にする人の意図の対象
public struct SubmissionTarget: Equatable, Sendable {
    public static let targetType = "submission"

    public var repo: RepositoryFullName
    public var version: MarketingVersion

    public init(repo: RepositoryFullName, version: MarketingVersion) {
        self.repo = repo
        self.version = version
    }

    /// 封筒の対象を読む。`revisioned` なら `targetVersion`（`revision`）を返し、そうでなければ `targetVersion` を持たないことを確かめる
    static func read(_ envelope: IntentEnvelope, kind: String, revisioned: Bool) throws(MalformedIntent) -> (Self, Int?) {
        guard envelope.kind == kind else { throw .init(detail: "kind が \(kind) でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == targetType, target.epic == nil,
              let version = target.id.flatMap(MarketingVersion.init(rawValue:)) else {
            throw .init(detail: "target がリリースを始めた版でない")
        }
        guard revisioned else {
            guard envelope.targetVersion == nil else { throw .init(detail: "\(kind) に targetVersion がある") }
            return (Self(repo: repo, version: version), nil)
        }
        guard let revision = envelope.targetVersion.flatMap(AnswerIntent.version) else {
            throw .init(detail: "targetVersion が準備の版（revision）でない")
        }
        return (Self(repo: repo, version: version), revision)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, id: version.rawValue) }
}

/// リリースを始める人の意図（`kind` が `startRelease`）。封筒の `repo` が対象のリポジトリで、`target`・`targetVersion` は持たない。
/// `version` は始める版（既定は前に配信した版の次のマイナー）。司令塔が release ブランチを作り、準備を進める
public struct StartReleaseIntent: Equatable, Sendable {
    public static let kind = "startRelease"

    public var repo: RepositoryFullName
    public var version: MarketingVersion
    public var intent: IntentReference

    public init(repo: RepositoryFullName, version: MarketingVersion, intent: IntentReference) {
        self.repo = repo
        self.version = version
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が startRelease でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "リリースを始める意図に target か targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["version"])
        guard let version = MarketingVersion(rawValue: try reader.text("version", required: true, limit: 32)) else {
            throw .init(detail: "version が版の番号の形でない")
        }
        self.init(repo: repo, version: version, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["version": .string(version.rawValue)] }
}

/// 審査に出す人の意図（`kind` が `submitForReview`）。`targetVersion` は人が見たときの準備の版（`revision`）。
/// `builds` は出すビルド（プラットフォームごと）、`whatsNew` は人が確かめた What's New（言語ごと。初めての版は空）、
/// `releaseType` は審査に通った後の配信の方式、`earliestReleaseDate` は `scheduled` のときの配信の日時、
/// `listing` は人が確かめた掲載文の直し（変える言語だけ。nil の欄は変えない。無ければ掲載文を変えない）、
/// `appReview` は人が確かめた App Review の情報の直し（nil の欄は変えない。無ければ変えない。パスワードは持たない）
public struct SubmitForReviewIntent: Equatable, Sendable {
    public static let kind = "submitForReview"
    /// 一度に出せるプラットフォームの数の上限
    public static let buildLimit = AppStorePlatform.allCases.count

    public var target: SubmissionTarget
    public var revision: Int
    public var builds: [SubmissionFile.BuildChoice]
    public var whatsNew: [LocalizedText]
    public var releaseType: AppStoreReleaseType
    public var earliestReleaseDate: Timestamp?
    public var listing: [ListingText]
    public var appReview: ReviewInformation?
    public var intent: IntentReference

    public init(
        target: SubmissionTarget,
        revision: Int,
        builds: [SubmissionFile.BuildChoice],
        whatsNew: [LocalizedText],
        releaseType: AppStoreReleaseType,
        earliestReleaseDate: Timestamp? = nil,
        listing: [ListingText] = [],
        appReview: ReviewInformation? = nil,
        intent: IntentReference
    ) {
        self.target = target
        self.revision = revision
        self.builds = builds
        self.whatsNew = whatsNew
        self.releaseType = releaseType
        self.earliestReleaseDate = earliestReleaseDate
        self.listing = listing
        self.appReview = appReview
        self.intent = intent
    }

    private struct Payload: Codable {
        var builds: [SubmissionFile.BuildChoice]
        var whatsNew: [LocalizedText]
        var releaseType: AppStoreReleaseType
        var earliestReleaseDate: Timestamp?
        var listing: [ListingText]?
        var appReview: ReviewInformation?
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, revision) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: true)
        let value = JSONValue.object(envelope.payload ?? [:])
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: CanonicalJSON.data(for: value))
        } catch {
            throw .init(detail: "payload の形が違う（\(error)）")
        }
        // 読んだ値を書き直したものに、送られた値がすべて含まれる（綴りの誤りなど、読み飛ばした欄が無い）
        guard let encoded = try? JSONValue(parsing: JSONEncoder().encode(payload)), value.isContained(in: encoded) else {
            throw .init(detail: "payload に知らない欄がある")
        }
        try Self.validate(payload)
        self.init(
            target: target,
            revision: revision ?? 0,
            builds: payload.builds,
            whatsNew: payload.whatsNew,
            releaseType: payload.releaseType,
            earliestReleaseDate: payload.earliestReleaseDate,
            listing: payload.listing ?? [],
            appReview: payload.appReview,
            intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        )
    }

    /// payload の欄どうしの決まり（ビルド・What's New・配信の方式と日時・掲載文・App Review の情報）
    private static func validate(_ payload: Payload) throws(MalformedIntent) {
        if payload.builds.isEmpty || payload.builds.count > Self.buildLimit { throw .init(detail: "builds は 1〜\(Self.buildLimit) 個") }
        if Set(payload.builds.map(\.platform)).count != payload.builds.count { throw .init(detail: "builds のプラットフォームが重複している") }
        if payload.builds.contains(where: { !ReleaseFile.isBuildNumber($0.build) }) { throw .init(detail: "builds の build の形が違う") }
        let problems = LocalizedText.problems(of: payload.whatsNew, name: "whatsNew")
        if !problems.isEmpty { throw .init(detail: problems.joined(separator: "、")) }
        if (payload.releaseType == .scheduled) != (payload.earliestReleaseDate != nil) {
            throw .init(detail: "earliestReleaseDate は、配信の方式が scheduled のときだけ持つ")
        }
        let listingProblems = ListingText.problems(of: payload.listing ?? [], name: "listing")
        if !listingProblems.isEmpty { throw .init(detail: listingProblems.joined(separator: "、")) }
        if let appReview = payload.appReview {
            if appReview.isEmpty { throw .init(detail: "appReview に変える欄が無い") }
            let problems = ReviewInformation.problems(of: appReview, name: "appReview")
            if !problems.isEmpty { throw .init(detail: problems.joined(separator: "、")) }
        }
    }

    public var targetVersion: String { String(revision) }

    public var payload: [String: JSONValue] {
        Self.payload(
            builds: builds,
            whatsNew: whatsNew,
            releaseType: releaseType,
            earliestReleaseDate: earliestReleaseDate,
            listing: listing,
            appReview: appReview
        )
    }

    /// 送る payload（クライアントが作る）。掲載文を変えないなら `listing` を送らない
    public static func payload(
        builds: [SubmissionFile.BuildChoice],
        whatsNew: [LocalizedText],
        releaseType: AppStoreReleaseType,
        earliestReleaseDate: Timestamp?,
        listing: [ListingText] = [],
        appReview: ReviewInformation? = nil
    ) -> [String: JSONValue] {
        let payload = Payload(
            builds: builds,
            whatsNew: whatsNew,
            releaseType: releaseType,
            earliestReleaseDate: earliestReleaseDate,
            listing: listing.isEmpty ? nil : listing,
            appReview: appReview
        )
        guard case let .object(fields)? = (try? JSONEncoder().encode(payload)).flatMap({ try? JSONValue(parsing: $0) }) else { return [:] }
        return fields
    }
}

/// 審査に通った版を配信する人の意図（`kind` が `distributeRelease`）。配信の方式が手動で、承認された（Pending Developer Release の）版だけ。
/// App Store Connect では取り消せない。payload は持たない
public struct DistributeReleaseIntent: Equatable, Sendable {
    public static let kind = "distributeRelease"

    public var target: SubmissionTarget
    public var intent: IntentReference

    public init(target: SubmissionTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, _) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: false)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}

/// 審査を取り下げる人の意図（`kind` が `withdrawSubmission`）。審査を待っている・審査中の版だけ。取り下げた後は、ビルドや What's New を
/// 直して審査に出し直せる（`submitForReview`）。payload は持たない
public struct WithdrawSubmissionIntent: Equatable, Sendable {
    public static let kind = "withdrawSubmission"

    public var target: SubmissionTarget
    public var intent: IntentReference

    public init(target: SubmissionTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, _) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: false)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}

/// このリリースをやめる人の意図（`kind` が `abandonRelease`）。審査に出す前・取り下げた後・断られた後だけ。記録に終わりの印を付けるだけで、
/// release ブランチ・App Store Connect の版は消さない。payload は持たない
public struct AbandonReleaseIntent: Equatable, Sendable {
    public static let kind = "abandonRelease"

    public var target: SubmissionTarget
    public var intent: IntentReference

    public init(target: SubmissionTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (target, _) = try SubmissionTarget.read(envelope, kind: Self.kind, revisioned: false)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}
