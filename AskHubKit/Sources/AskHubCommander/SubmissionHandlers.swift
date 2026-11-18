import AskHubProtocol
import AskHubStateStore
import Foundation

// リリースを始めてから配信までの人の意図の処理（`docs/renewal/release.md` の「リリースを始めてから配信まで」）。
// どれも `submissions/<版>.json` に人の意図を写すだけで、GitHub・App Store Connect の操作は見回り（`ReleaseWatch`）が行う
// （人の意図の処理の中で外の操作を待たない。途中で止まっても、見回りがやり直す）

/// リリースを始める（`startRelease`）を受け付け、`submissions/<版>.json` を作る。
/// 終わっていないリリースがある・配信した版より大きくない・もう始めた版なら断る。やめた版は始め直せる
public struct StartReleaseHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let start: StartReleaseIntent
        do {
            start = try StartReleaseIntent(envelope: envelope)
        } catch {
            return .reject("リリースを始める意図の形が違う（\(error.detail)）")
        }
        let path = StatePath.submission(start.repo, start.version)
        let existing = try await context.read(SubmissionFile.self, at: path)
        // 前の周で作った（やり直し）
        if existing?.start?.approval == start.intent { return .accept }
        if let problem = try await Self.problem(starting: start, existing: existing, in: context) { return .reject(problem) }
        let file = SubmissionFile(
            repo: start.repo,
            version: start.version,
            origin: .askhub,
            start: .init(approval: start.intent, at: context.timestamp),
            createdAt: context.timestamp,
            updatedAt: context.timestamp
        )
        let message = "\(start.repo) の \(start.version) のリリースを始める"
        do {
            if existing == nil {
                try await context.files.create(file, at: path, message: message)
            } else {
                // やめた版を始め直す（前の記録は置き換える。release ブランチが残っていれば、見回りがそのまま使う）
                try await context.files.update(SubmissionFile.self, at: path, message: message) { current in
                    guard current.end?.reason == .abandoned else { return false }
                    current = file
                    return true
                }
            }
        } catch .alreadyExists {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
        return .accept
    }

    /// 始められない理由。始められれば nil
    static func problem(
        starting start: StartReleaseIntent,
        existing: SubmissionFile?,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        guard let repository = try await context.read(RepositoryFile.self, at: StatePath.repository(start.repo)) else {
            return "\(start.repo) は対象のリポジトリに加えていない"
        }
        if repository.isRemoved { return "\(start.repo) は対象から外した。リリースを始めるには加え直す" }
        if repository.platform != .apple { return "\(start.repo) は App Store のアプリのリポジトリでない" }
        if let existing, existing.end?.reason != .abandoned {
            return existing.isEnded ? "\(start.version) はもう配信した" : "\(start.version) のリリースはもう始めている"
        }
        for other in try await submissions(of: start.repo, in: context) where !other.isEnded && other.version != start.version {
            return "\(other.version) のリリースが終わっていない。先にやめるか、配信を待つ（App Store Connect の編集できる版は 1 つ）"
        }
        if let released = try await releasedVersions(of: start.repo, in: context).max(), start.version <= released {
            return "配信した版（\(released)）より大きい版にする"
        }
        return nil
    }

    /// リポジトリのリリースを始めた版の記録（読めないものは飛ばす）
    static func submissions(of repo: RepositoryFullName, in context: CommanderContext) async throws(CommanderError) -> [SubmissionFile] {
        var files: [SubmissionFile] = []
        for version in try await versions(in: StatePath.submissions(repo), context: context) {
            if let file = try await context.readable(SubmissionFile.self, at: StatePath.submission(repo, version)) { files.append(file) }
        }
        return files
    }

    /// 配信した版（`releases/<版>.json` の名前）
    static func releasedVersions(
        of repo: RepositoryFullName,
        in context: CommanderContext
    ) async throws(CommanderError) -> [MarketingVersion] {
        try await versions(in: StatePath.releases(repo), context: context)
    }

    private static func versions(in directory: String, context: CommanderContext) async throws(CommanderError) -> [MarketingVersion] {
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.list(directory) ?? []
        } catch {
            throw .store(error)
        }
        return entries.filter { $0.kind == .file && $0.name.hasSuffix(".json") }
            .compactMap { MarketingVersion(rawValue: String($0.name.dropLast(".json".count))) }
    }
}

/// このリリースをやめる（`abandonRelease`）を受け付け、記録に終わりの印を付ける。審査に出していない・取り下げた・断られた版だけ。
/// release ブランチ・develop の版を上げる PR・App Store Connect の版には触れない
public struct AbandonReleaseHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let abandon: AbandonReleaseIntent
        do {
            abandon = try AbandonReleaseIntent(envelope: envelope)
        } catch {
            return .reject("リリースをやめる意図の形が違う（\(error.detail)）")
        }
        let target = abandon.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        // 前の周で書いた（やり直し）
        if file.end?.approval == abandon.intent { return .accept }
        if let problem = Self.problem(abandoning: file) { return .reject(problem) }
        let end = SubmissionFile.End(reason: .abandoned, at: context.timestamp, approval: abandon.intent)
        let saved: SubmissionFile
        do {
            let message = "\(target.repo) の \(target.version) のリリースをやめる"
            saved = try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                guard Self.problem(abandoning: file) == nil else { return false }
                file.end = end
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.end == end else { throw .changedWhileProcessing(path) }
        return .accept
    }

    static func problem(abandoning file: SubmissionFile) -> String? {
        if file.isEnded { return "\(file.version) のリリースはもう終わっている" }
        if file.isSubmitting { return "\(file.version) を審査に出している途中。出し終えてから取り下げる" }
        if file.hasReviewInFlight { return "\(file.version) は審査中か、審査に通っている。やめるには先に審査を取り下げる" }
        return nil
    }
}
