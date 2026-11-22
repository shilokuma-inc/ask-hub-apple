import AskHubProtocol
import AskHubStateStore
import Foundation

// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の人の意図の受け付け（`docs/renewal/creative-assets.md`）。
// どちらも `creative.json` に写すだけで、Claude の案・書き出し・App Store Connect への書き込みは見回り（`ReleaseWatch+Creative`）が行う

/// 案を頼む・直してほしいことを書く（`draftCreativeAssets`）を受け付け、新しい案の版を `drafting` で作る。
/// 人が見た案の版が今の案と違えば断る（見ていない案を直さない）。書き出し終えた今の案は、見比べるために前の案に移す
public struct DraftCreativeAssetsHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let intent: DraftCreativeAssetsIntent
        do {
            intent = try DraftCreativeAssetsIntent(envelope: envelope)
        } catch {
            return .reject("クリエイティブアセットの案を頼む意図の形が違う（\(error.detail)）")
        }
        guard let settings = try await context.read(RepositoryFile.self, at: StatePath.repository(intent.repo)),
              settings.removedAt == nil, settings.platform == .apple else {
            return .reject("\(intent.repo) は Apple のアプリの対象のリポジトリでない")
        }
        let path = StatePath.creative(intent.repo)
        let current = try await context.read(CreativeFile.self, at: path)
        // 前の周で写した（やり直し）
        if current?.draft?.request.approval == intent.intent { return .accept }
        if let problem = Self.problem(intent, file: current) { return .reject(problem) }
        let request = CreativeFile.Request(approval: intent.intent, comment: intent.comment, at: context.timestamp)
        let message = "\(intent.repo) のクリエイティブアセットの案を頼まれた"
        let saved: CreativeFile
        do throws(StateFileStore.Failure) {
            if current == nil {
                var file = CreativeFile(repo: intent.repo, updatedAt: context.timestamp)
                Self.start(&file, request: request)
                do throws(StateFileStore.Failure) {
                    try await context.files.create(file, at: path, message: message)
                    return .accept
                } catch .alreadyExists {
                    // 読んだ後に作られた。下で書き直す
                }
            }
            saved = try await context.files.update(CreativeFile.self, at: path, message: message) { file in
                guard Self.problem(intent, file: file) == nil else { return false }
                Self.start(&file, request: request)
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.draft?.request == request else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 受け付けられないわけ（人が見た案の版が今の案と違う）
    static func problem(_ intent: DraftCreativeAssetsIntent, file: CreativeFile?) -> String? {
        let current = file?.draft?.revision ?? 0
        guard intent.revision == current else {
            return "クリエイティブアセットの案が新しくなった（見た案は \(intent.revision)、今は \(current)）。今の案を見てから頼む"
        }
        return nil
    }

    /// 新しい案の版を始める。書き出し終えた今の案は前の案に移し（Claude が直すもとにもなる）、撮った 6.9 インチの画面の実行は引き継ぐ（撮り直さない）
    static func start(_ file: inout CreativeFile, request: CreativeFile.Request) {
        let old = file.draft
        if let old, let spec = old.spec, !old.images.isEmpty {
            file.previous = .init(revision: old.revision, spec: spec, images: old.images)
        }
        file.draft = .init(revision: (old?.revision ?? 0) + 1, request: request, state: .drafting, screenshotsRun: old?.screenshotsRun)
        file.problem = nil
    }
}

/// 書き出した案を承認する（`approveCreativeAssets`）を受け付け、`approved` に写す。人が見た案の版が今の案で、書き出しが終わったときだけ。
/// 前に承認した案は上書きする（次のリリースで置くのは、最後に承認した案）
public struct ApproveCreativeAssetsHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let intent: ApproveCreativeAssetsIntent
        do {
            intent = try ApproveCreativeAssetsIntent(envelope: envelope)
        } catch {
            return .reject("クリエイティブアセットの案を承認する意図の形が違う（\(error.detail)）")
        }
        let path = StatePath.creative(intent.repo)
        guard let current = try await context.read(CreativeFile.self, at: path) else {
            return .reject("\(intent.repo) のクリエイティブアセットの案が無い")
        }
        // 前の周で写した（やり直し）
        if current.approved?.approval == intent.intent { return .accept }
        if let problem = Self.problem(intent, file: current) { return .reject(problem) }
        let saved: CreativeFile
        do {
            let message = "\(intent.repo) のクリエイティブアセットの案を承認した"
            saved = try await context.files.update(CreativeFile.self, at: path, message: message) { file in
                guard Self.problem(intent, file: file) == nil, let draft = file.draft, let spec = draft.spec else { return false }
                file.approved = .init(
                    revision: draft.revision, spec: spec, images: draft.images, approval: intent.intent, at: context.timestamp
                )
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.approved?.approval == intent.intent else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 承認できないわけ（今の案でない・書き出しが終わっていない）
    static func problem(_ intent: ApproveCreativeAssetsIntent, file: CreativeFile) -> String? {
        guard let draft = file.draft, draft.revision == intent.revision else {
            return "クリエイティブアセットの案が新しくなった（見た案は \(intent.revision)、今は \(file.draft?.revision ?? 0)）。今の案を見てから承認する"
        }
        guard draft.awaitsReview else { return "クリエイティブアセットの案 \(draft.revision) は、まだ書き出しが終わっていない" }
        return nil
    }
}
