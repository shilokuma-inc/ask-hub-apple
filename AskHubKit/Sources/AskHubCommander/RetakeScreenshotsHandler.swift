import AskHubProtocol
import AskHubStateStore
import Foundation

/// スクショを撮り直す（`retakeScreenshots`）を受け付け、頼みを記録（`screenshots.retake`）に写す。撮り直しは見回りが行う
/// （`ReleaseWatch+ScreenshotRetake`。`docs/renewal/store-screenshots.md` の「撮り直す」）。審査に出す前だけ受け付ける
public struct RetakeScreenshotsHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let retake: RetakeScreenshotsIntent
        do {
            retake = try RetakeScreenshotsIntent(envelope: envelope)
        } catch {
            return .reject("スクショを撮り直す意図の形が違う（\(error.detail)）")
        }
        let target = retake.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        // 前の周で写した（やり直し）
        if file.screenshots?.retake?.approval == retake.intent { return .accept }
        if let problem = Self.problem(retaking: file) { return .reject(problem) }
        let request = SubmissionFile.Retake(
            displayTypes: retake.displayTypes, locales: retake.locales, approval: retake.intent, at: context.timestamp
        )
        let saved: SubmissionFile
        do {
            let message = "\(target.repo) の \(target.version) のスクショを撮り直す"
            saved = try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                guard Self.problem(retaking: file) == nil else { return false }
                file.screenshots?.retake = request
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.screenshots?.retake == request else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 撮り直せないわけ（記録の決まり。アプリも同じものを使う）
    static func problem(retaking file: SubmissionFile) -> String? {
        file.retakeProblem
    }
}
