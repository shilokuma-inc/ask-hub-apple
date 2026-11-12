import AskHubProtocol
import AskHubStateStore
import Foundation

/// リリース文を確かめて GitHub Release を公開する人の意図（`publishGitHubRelease`）。
///
/// 押した本文を配信の記録の `notes.confirmed` に写すだけで、GitHub Release は次の見回り（`ReleaseWatch`）で公開する
/// （人の意図の処理の中で GitHub を待たない。公開が途中で止まっても、見回りがやり直す）
public struct PublishGitHubReleaseHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let publish: PublishGitHubReleaseIntent
        do {
            publish = try PublishGitHubReleaseIntent(envelope: envelope)
        } catch {
            return .reject("GitHub Release を公開する意図の形が違う（\(error.detail)）")
        }
        let target = publish.target
        let path = StatePath.release(target.repo, target.version)
        guard let file = try await context.read(ReleaseFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) の配信の記録が無い")
        }
        // 前の周で写した（やり直し）
        if file.notes?.confirmed?.approval == publish.intent { return .accept }
        if let problem = Self.problem(publishing: publish, on: file) { return .reject(problem) }
        let confirmed = ReleaseFile.ConfirmedNotes(text: publish.notes, approval: publish.intent, at: context.timestamp)
        let saved: ReleaseFile
        do {
            let message = "\(target.repo) の \(target.version) のリリース文を確かめた"
            saved = try await context.files.update(ReleaseFile.self, at: path, message: message) { file in
                guard Self.problem(publishing: publish, on: file) == nil else { return false }
                file.notes?.confirmed = confirmed
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        // 読んだ後に書き換わった（下書きの作り直し・ほかの意図で公開を押した）。次の周で読み直して決める
        guard saved.notes?.confirmed == confirmed else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 受け付けられない理由。受け付けられれば nil
    static func problem(publishing publish: PublishGitHubReleaseIntent, on file: ReleaseFile) -> String? {
        if file.githubRelease != nil { return "\(file.version) の GitHub Release はもう公開している" }
        guard let notes = file.notes else { return "\(file.version) のリリース文の下書きがまだ無い" }
        guard notes.version == publish.target.notesVersion else {
            return "\(file.version) のリリース文の下書きが作り直された（今の版は \(notes.version)）。新しい下書きを見てから送り直す"
        }
        if notes.confirmed != nil { return "\(file.version) の公開はもう受け付けている" }
        return nil
    }
}
