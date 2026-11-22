@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let submissionTarget = IntentEnvelope.Target(type: "submission", id: "1.4.0")
    static let submissionKinds: [Kind] = [
        Kind(vectors: "payloads/startRelease.json", kind: "startRelease", target: nil, targetVersion: nil) {
            try StartReleaseIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/submitForReview.json", kind: "submitForReview", target: submissionTarget, targetVersion: "2") {
            try SubmitForReviewIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/distributeRelease.json", kind: "distributeRelease", target: submissionTarget, targetVersion: nil) {
            try DistributeReleaseIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/withdrawSubmission.json", kind: "withdrawSubmission", target: submissionTarget, targetVersion: nil) {
            try WithdrawSubmissionIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/abandonRelease.json", kind: "abandonRelease", target: submissionTarget, targetVersion: nil) {
            try AbandonReleaseIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/retakeScreenshots.json", kind: "retakeScreenshots", target: submissionTarget, targetVersion: nil) {
            try RetakeScreenshotsIntent(envelope: $0).payload
        }
    ]
}

/// リリースを始めた版の記録（`submissions/<版>.json`）と、リリースを始めてから配信までの人の意図
struct SubmissionProtocolTests {
    private static let at = Timestamp(rawValue: "2026-11-20T01:00:00Z")!
    private static let reference = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
    )

    private func envelope(
        kind: String,
        target: IntentEnvelope.Target?,
        targetVersion: String?,
        payload: [String: JSONValue] = [:],
        repo: String? = "shilokuma-inc/prime-pick-ios"
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: repo.flatMap(RepositoryFullName.init(rawValue:)),
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-20T02:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func file(
        builds: [SubmissionFile.Build] = [.init(platform: .iOS, build: "45")],
        whatsNew: SubmissionFile.WhatsNew? = .init(drafts: [.init(locale: "ja", text: "速くなりました")], draftedAt: at),
        listing: SubmissionFile.Listing? = .init(
            current: [.init(locale: "ja", description: "素数のクイズ")], drafts: [], reason: "変えない", draftedAt: at
        ),
        submit: SubmissionFile.Submit? = nil,
        review: [SubmissionFile.Review] = [],
        withdrawal: SubmissionFile.Request? = nil,
        end: SubmissionFile.End? = nil
    ) -> SubmissionFile {
        SubmissionFile(
            repo: RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!,
            version: MarketingVersion(rawValue: "1.4.0")!,
            origin: .askhub,
            start: .init(approval: Self.reference, at: Self.at),
            builds: builds,
            whatsNew: whatsNew,
            listing: listing,
            screenshots: .init(state: .notConfigured, startedAt: Self.at, finishedAt: Self.at),
            revision: 2,
            submit: submit,
            review: review,
            withdrawal: withdrawal,
            end: end,
            createdAt: Self.at,
            updatedAt: Self.at
        )
    }

    private func submit(at text: String = "2026-11-20T02:00:00Z") -> SubmissionFile.Submit {
        SubmissionFile.Submit(
            approval: Self.reference,
            at: Timestamp(rawValue: text)!,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [.init(locale: "ja", text: "速くなりました")],
            releaseType: .afterApproval
        )
    }

    private func review(_ state: AppStoreVersionState, submittedAt: String? = "2026-11-20T02:01:00Z") -> SubmissionFile.Review {
        SubmissionFile.Review(platform: .iOS, state: state, since: Self.at, submittedAt: submittedAt.flatMap(Timestamp.init(rawValue:)))
    }

    // MARK: - 状態

    @Test func convertsAppStoreConnectStates() {
        #expect(AppStoreVersionState.inReview.appStoreConnectValue == "IN_REVIEW")
        #expect(AppStoreVersionState.waitingForExportCompliance.appStoreConnectValue == "WAITING_FOR_EXPORT_COMPLIANCE")
        for state in AppStoreVersionState.allCases {
            #expect(AppStoreVersionState(appStoreConnectValue: state.appStoreConnectValue) == state)
        }
        #expect(AppStoreVersionState(appStoreConnectValue: "inReview") == nil)
        #expect(AppStoreReleaseType.afterApproval.appStoreConnectValue == "AFTER_APPROVAL")
    }

    @Test func awaitsSubmissionOnlyWhenPrepared() {
        #expect(file().awaitsSubmission)
        #expect(!file(builds: []).awaitsSubmission)
        #expect(!file(whatsNew: nil).awaitsSubmission)
        #expect(!file(listing: nil).awaitsSubmission)
        // 初めての版は What's New を持たない（下書きが空でも準備はそろっている）
        #expect(file(whatsNew: .init(drafts: [], draftedAt: Self.at)).awaitsSubmission)
        #expect(!file(submit: submit()).awaitsSubmission)
        #expect(!file(end: .init(reason: .abandoned, at: Self.at, approval: Self.reference)).awaitsSubmission)
        // 取り下げた後は、出し直せる
        #expect(file(review: [review(.developerRejected)]).awaitsSubmission)
        #expect(!file(review: [review(.inReview)]).awaitsSubmission)
    }

    @Test func tracksSubmittingUntilEveryPlatformIsSubmitted() {
        #expect(file(submit: submit()).isSubmitting)
        #expect(!file(submit: submit(), review: [review(.waitingForReview)]).isSubmitting)
        // 前に出した印は、新しく押した審査に出すの印にならない
        #expect(file(submit: submit(at: "2026-11-21T00:00:00Z"), review: [review(.developerRejected)]).isSubmitting)
        #expect(!file().isSubmitting)
    }

    @Test func offersWithdrawAndAbandonByState() {
        #expect(file(submit: submit(), review: [review(.waitingForReview)]).canWithdraw)
        #expect(file(submit: submit(), review: [review(.inReview)]).canWithdraw)
        #expect(!file(submit: submit(), review: [review(.pendingDeveloperRelease)]).canWithdraw)
        let sending = SubmissionFile.Request(approval: Self.reference, at: Self.at)
        #expect(!file(submit: submit(), review: [review(.inReview)], withdrawal: sending).canWithdraw)

        #expect(file().canAbandon)
        #expect(!file(submit: submit()).canAbandon)
        #expect(!file(submit: submit(), review: [review(.inReview)]).canAbandon)
        #expect(file(submit: submit(), review: [review(.rejected)]).canAbandon)
        #expect(file(review: [review(.developerRejected)]).canAbandon)
    }

    @Test func awaitsDistributionWhenApprovedForManualRelease() {
        #expect(file(submit: submit(), review: [review(.pendingDeveloperRelease)]).awaitsDistribution)
        #expect(!file(submit: submit(), review: [review(.processingForDistribution)]).awaitsDistribution)
        var requested = file(submit: submit(), review: [review(.pendingDeveloperRelease)])
        requested.distribution = .init(approval: Self.reference, at: Self.at)
        #expect(!requested.awaitsDistribution)
    }

    @Test func checksLocales() {
        #expect(LocalizedText.isLocale("ja"))
        #expect(LocalizedText.isLocale("en-US"))
        #expect(LocalizedText.isLocale("zh-Hans"))
        #expect(LocalizedText.isLocale("es-419"))
        #expect(!LocalizedText.isLocale("JA"))
        #expect(!LocalizedText.isLocale("en_US"))
        #expect(!LocalizedText.isLocale("e"))
        #expect(!LocalizedText.isLocale("en-"))
        #expect(!LocalizedText.isLocale("../ja"))
    }

    // MARK: - 人の意図

    @Test func readsStartRelease() throws {
        let intent = try StartReleaseIntent(envelope: envelope(
            kind: "startRelease", target: nil, targetVersion: nil, payload: ["version": .string("1.4.0")]
        ))
        #expect(intent.repo.rawValue == "shilokuma-inc/prime-pick-ios")
        #expect(intent.version.rawValue == "1.4.0")
        #expect(throws: MalformedIntent.self) {
            try StartReleaseIntent(envelope: envelope(
                kind: "startRelease", target: nil, targetVersion: "1", payload: ["version": .string("1.4.0")]
            ))
        }
        #expect(throws: MalformedIntent.self) {
            try StartReleaseIntent(envelope: envelope(
                kind: "startRelease", target: nil, targetVersion: nil, payload: ["version": .string("1.4.0")], repo: nil
            ))
        }
    }

    @Test func readsSubmitForReview() throws {
        let payload: [String: JSONValue] = [
            "builds": .array([.object(["platform": .string("iOS"), "build": .string("45")])]),
            "whatsNew": .array([.object(["locale": .string("ja"), "text": .string("速くなりました")])]),
            "releaseType": .string("scheduled"),
            "earliestReleaseDate": .string("2026-11-25T00:00:00Z")
        ]
        let target = IntentEnvelope.Target(type: "submission", id: "1.4.0")
        let intent = try SubmitForReviewIntent(envelope: envelope(
            kind: "submitForReview", target: target, targetVersion: "3", payload: payload
        ))
        #expect(intent.target.version.rawValue == "1.4.0")
        #expect(intent.revision == 3)
        #expect(intent.targetVersion == "3")
        #expect(intent.builds == [.init(platform: .iOS, build: "45")])
        #expect(intent.releaseType == .scheduled)
        #expect(intent.earliestReleaseDate?.rawValue == "2026-11-25T00:00:00Z")
        #expect(intent.payload == payload)
    }

    @Test(arguments: [
        (IntentEnvelope.Target?.none, String?("1")),
        (IntentEnvelope.Target(type: "release", id: "1.4.0"), "1"),
        (IntentEnvelope.Target(type: "submission", epic: ULID(rawValue: "01JCEP1C000000000000000001"), id: "1.4.0"), "1"),
        (IntentEnvelope.Target(type: "submission", id: "../1.4.0"), "1"),
        (IntentEnvelope.Target(type: "submission", id: nil), "1"),
        (IntentEnvelope.Target(type: "submission", id: "1.4.0"), "0"),
        (IntentEnvelope.Target(type: "submission", id: "1.4.0"), "01"),
        (IntentEnvelope.Target(type: "submission", id: "1.4.0"), nil)
    ] as [(IntentEnvelope.Target?, String?)])
    func rejectsSubmitWithWrongTarget(target: IntentEnvelope.Target?, targetVersion: String?) {
        let payload: [String: JSONValue] = [
            "builds": .array([.object(["platform": .string("iOS"), "build": .string("45")])]),
            "whatsNew": .array([]),
            "releaseType": .string("manual")
        ]
        #expect(throws: MalformedIntent.self) {
            try SubmitForReviewIntent(envelope: envelope(
                kind: "submitForReview", target: target, targetVersion: targetVersion, payload: payload
            ))
        }
    }

    @Test(arguments: ["distributeRelease", "withdrawSubmission", "abandonRelease"])
    func readsStateIntents(kind: String) throws {
        let target = IntentEnvelope.Target(type: "submission", id: "1.4.0")
        let read: (IntentEnvelope) throws -> SubmissionTarget = { envelope in
            switch kind {
            case "distributeRelease": try DistributeReleaseIntent(envelope: envelope).target
            case "withdrawSubmission": try WithdrawSubmissionIntent(envelope: envelope).target
            default: try AbandonReleaseIntent(envelope: envelope).target
            }
        }
        #expect(try read(envelope(kind: kind, target: target, targetVersion: nil)).version.rawValue == "1.4.0")
        #expect(try read(envelope(kind: kind, target: target, targetVersion: nil)).target == target)
        // 今の状態に対してだけ意味を持つので、targetVersion があれば読まない
        #expect(throws: (any Error).self) { try read(envelope(kind: kind, target: target, targetVersion: "1")) }
        #expect(throws: (any Error).self) { try read(envelope(kind: "pauseEpic", target: target, targetVersion: nil)) }
        #expect(throws: (any Error).self) { try read(envelope(kind: kind, target: target, targetVersion: nil, repo: nil)) }
    }

    @Test func pathsAreUnderTheRepository() {
        let repo = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!
        let path = StatePath.submission(repo, MarketingVersion(rawValue: "1.4.0")!)
        #expect(path == "repos/shilokuma-inc/prime-pick-ios/submissions/1.4.0.json")
        #expect(SubmissionFile.branchName(for: MarketingVersion(rawValue: "1.4.0")!) == "release/1.4.0")
    }
}
