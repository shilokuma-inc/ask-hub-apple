import Foundation

/// 人の意図の種類ごとの処理の表
extension CommanderLoop {
    /// 人の意図の種類ごとの処理。`admin` が nil（ワーカー・テスト）なら、管理の操作（保護の設定）は理由を付けて断る
    static func handlers(admin: AdminGitHub?) -> [String: any IntentHandler] {
        let administered: [String: any IntentHandler] = [
            "addRepository": AddRepositoryHandler(admin: admin),
            "applyProtection": ApplyProtectionHandler(admin: admin),
            "approveSetupPullRequest": ApproveSetupPullRequestHandler(admin: admin)
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
        "decision": DecisionHandler(),
        "approveMerge": ApproveMergeHandler(),
        "instructFinal": InstructFinalHandler(),
        "humanTaskDone": HumanTaskDoneHandler(),
        "verify": VerifyHandler(),
        "publishGitHubRelease": PublishGitHubReleaseHandler(),
        "updatePromotionalText": UpdatePromotionalTextHandler(),
        "startRelease": StartReleaseHandler(),
        "submitForReview": SubmitForReviewHandler(),
        "distributeRelease": DistributeReleaseHandler(),
        "withdrawSubmission": WithdrawSubmissionHandler(),
        "abandonRelease": AbandonReleaseHandler(),
        "registerBundleId": RegisterBundleIdHandler(),
        "applyAppStoreSettings": ApplyAppStoreSettingsHandler(),
        "confirmAppStoreItem": ConfirmAppStoreItemHandler(),
        "excludeFromAppStore": ExcludeFromAppStoreHandler(),
        "findCleanupCandidates": CleanupRequestHandler(),
        "removeCleanupCandidates": CleanupRequestHandler()
    ]
}
