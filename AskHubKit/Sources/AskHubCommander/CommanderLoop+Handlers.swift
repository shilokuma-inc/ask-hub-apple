import AskHubProtocol
import Foundation

/// 人の意図の種類ごとの処理の表
extension CommanderLoop {
    /// 人の意図の種類ごとの処理。`admin` が nil（ワーカー・テスト）なら、管理の操作（保護の設定）は理由を付けて断る。
    /// `appKit` が nil なら、対象に加えるときの準備に app-kit への入れ替えを足さない。`appKitPilot` は app-kit の版を広げる試しの 1 本
    static func handlers(
        admin: AdminGitHub?,
        appKit: (any AppKitSource)? = nil,
        appKitPilot: RepositoryFullName = AppKitPolicy.defaultPilot
    ) -> [String: any IntentHandler] {
        let administered: [String: any IntentHandler] = [
            "addRepository": AddRepositoryHandler(admin: admin, appKit: appKit),
            "createRepository": CreateRepositoryHandler(admin: admin, appKit: appKit),
            "readSecretsKey": ReadSecretsKeyHandler(admin: admin),
            "humanTaskDone": HumanTaskDoneHandler(admin: admin),
            "applyProtection": ApplyProtectionHandler(admin: admin),
            "approveSetupPullRequest": ApproveSetupPullRequestHandler(admin: admin),
            "rolloutAppKit": RolloutAppKitHandler(admin: admin, pilot: appKitPilot),
            "stopAppKitRollout": StopAppKitRolloutHandler(admin: admin)
        ]
        return commonHandlers.merging(administered) { _, administered in administered }
    }

    /// 管理用のトークンを使わない処理
    static let commonHandlers: [String: any IntentHandler] = [
        "request": RequestHandler(),
        "answer": AnswerHandler(),
        "startEpic": StartEpicHandler(),
        "reviseGoal": ReviseGoalHandler(),
        "decideSplit": DecideSplitHandler(),
        "abandonEpic": AbandonEpicHandler(),
        "pauseEpic": PauseEpicHandler(),
        "resumeEpic": ResumeEpicHandler(),
        "handover": HandoverHandler(),
        "configureRepository": ConfigureRepositoryHandler(),
        "removeRepository": RemoveRepositoryHandler(),
        "retry": RetryJobHandler(),
        "giveUp": GiveUpJobHandler(),
        "skipTask": SkipTaskHandler(),
        "decision": DecisionHandler(),
        "approveMerge": ApproveMergeHandler(),
        "instructFinal": InstructFinalHandler(),
        "verify": VerifyHandler(),
        "publishGitHubRelease": PublishGitHubReleaseHandler(),
        "updatePromotionalText": UpdatePromotionalTextHandler(),
        "startRelease": StartReleaseHandler(),
        "submitForReview": SubmitForReviewHandler(),
        "distributeRelease": DistributeReleaseHandler(),
        "withdrawSubmission": WithdrawSubmissionHandler(),
        "abandonRelease": AbandonReleaseHandler(),
        "retakeScreenshots": RetakeScreenshotsHandler(),
        "draftCreativeAssets": DraftCreativeAssetsHandler(),
        "approveCreativeAssets": ApproveCreativeAssetsHandler(),
        "reportRejection": ReportRejectionHandler(),
        "resolveRejection": ResolveRejectionHandler(),
        "registerBundleId": RegisterBundleIdHandler(),
        "applyAppStoreSettings": ApplyAppStoreSettingsHandler(),
        "confirmAppStoreItem": ConfirmAppStoreItemHandler(),
        "excludeFromAppStore": ExcludeFromAppStoreHandler(),
        "findCleanupCandidates": CleanupRequestHandler(),
        "removeCleanupCandidates": CleanupRequestHandler()
    ]
}
