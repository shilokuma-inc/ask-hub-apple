import AskHubProtocol
import AskHubStateStore
import Foundation

// リリースを始めてから配信までの人の意図の処理（`docs/renewal/release.md` の「リリースを始めてから配信まで」）。
// どれも `submissions/<版>.json` に人の意図を写すだけで、GitHub・App Store Connect の操作は見回り（`ReleaseWatch`）が行う
// （人の意図の処理の中で外の操作を待たない。途中で止まっても、見回りがやり直す）

/// リリースを始める（`startRelease`）を受け付け、`submissions/<版>.json` を作る。
/// 終わっていないリリースがある・配信した版より大きくない・もう始めた版なら断る。やめた版は始め直せる。
/// hotfix は配信中の版の次のパッチだけで、進行中のリリースがあれば、人が確かめた版（`suspend`）を一時停止してから始める
/// （審査中なら取り下げを頼む。審査に通った版は API で取り下げられないので断る）
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
        let released = try await Self.releasedVersions(of: start.repo, in: context).max()
        if let suspend = start.suspend { try await Self.suspend(suspend, for: start, in: context) }
        // App Store Connect の版の枠は、見回りが作る（空の並びは「これから作る」の印）
        let file = SubmissionFile(
            repo: start.repo,
            version: start.version,
            origin: .askhub,
            start: .init(approval: start.intent, at: context.timestamp),
            hotfix: start.hotfix ? released.map { .init(from: $0, suspended: start.suspend) } : nil,
            appStoreVersions: [],
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
        let released = try await releasedVersions(of: start.repo, in: context).max()
        let others = try await submissions(of: start.repo, in: context).filter { !$0.isEnded && $0.version != start.version }
        if start.hotfix {
            return hotfixProblem(start, released: released, others: others)
        }
        if let other = others.first {
            return "\(other.version) のリリースが終わっていない。先にやめるか、配信を待つ（App Store Connect の編集できる版は 1 つ）"
        }
        if let released, start.version <= released {
            return "配信した版（\(released)）より大きい版にする"
        }
        return nil
    }

    /// hotfix を始められない理由。版は配信中の版の次のパッチだけ。進行中のリリースは、人が確かめた版を一時停止できるときだけ
    static func hotfixProblem(_ start: StartReleaseIntent, released: MarketingVersion?, others: [SubmissionFile]) -> String? {
        guard let released else { return "配信した版が無いので、hotfix は始められない" }
        guard start.version == released.nextPatch else {
            return "hotfix の版は、配信中の版（\(released)）の次のパッチ（\(released.nextPatch)）にする"
        }
        for other in others {
            if other.hotfix != nil { return "hotfix の \(other.version) が終わっていない" }
            // 前の周で一時停止を書いた（やり直し）
            if other.suspension?.approval == start.intent, other.isSuspended { continue }
            guard start.suspend == other.version else {
                return "進行中の \(other.version) のリリースを一時停止することを確かめてから始める（取り直して送り直す）"
            }
            if other.isSuspended { return "\(other.version) はもう別の hotfix で一時停止している" }
            if other.isSubmitting { return "\(other.version) を審査に出している途中。出し終えてから hotfix を始める" }
            if other.review.contains(where: { $0.state.isApproved || $0.state == .readyForDistribution }) {
                return "\(other.version) は審査に通っている（API で取り下げられない）。配信するか、App Store Connect で取り下げてから hotfix を始める"
            }
        }
        if let suspend = start.suspend, !others.contains(where: { $0.version == suspend }) {
            return "一時停止する \(suspend) のリリースが無い（取り直して送り直す）"
        }
        return nil
    }

    /// 進行中のリリースを hotfix の間一時停止する。審査を待っている・審査中なら、取り下げも頼む（見回りが取り下げる）
    static func suspend(
        _ version: MarketingVersion,
        for start: StartReleaseIntent,
        in context: CommanderContext
    ) async throws(CommanderError) {
        let path = StatePath.submission(start.repo, version)
        let suspension = SubmissionFile.Suspension(by: start.version, approval: start.intent, at: context.timestamp)
        let saved: SubmissionFile
        do {
            let message = "\(start.repo) の \(version) を hotfix の間一時停止する"
            saved = try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                guard !file.isEnded, file.suspension?.approval != start.intent else { return false }
                file.suspension = suspension
                if file.canWithdraw { file.withdrawal = .init(approval: start.intent, at: context.timestamp) }
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.suspension?.approval == start.intent else { throw .changedWhileProcessing(path) }
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

/// 審査に出す（`submitForReview`）を受け付け、出す中身を記録に写す。App Store Connect には見回りが出す。
/// 人が見たときの準備の版（`revision`）でない・準備がそろっていない・出せない状態なら断る
public struct SubmitForReviewHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let submit: SubmitForReviewIntent
        do {
            submit = try SubmitForReviewIntent(envelope: envelope)
        } catch {
            return .reject("審査に出す意図の形が違う（\(error.detail)）")
        }
        let target = submit.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        // 前の周で写した（やり直し）
        if file.submit?.approval == submit.intent { return .accept }
        if let problem = Self.problem(submitting: submit, on: file, now: context.now()) { return .reject(problem) }
        // 載せるクリエイティブアセットは、人が承認した今の案で、ライブラリで置ける状態になったものだけ
        if let choice = submit.creative {
            let creative = try await context.read(CreativeFile.self, at: StatePath.creative(target.repo))
            if let problem = Self.problem(creative: choice, on: creative) { return .reject(problem) }
        }
        let request = SubmissionFile.Submit(
            approval: submit.intent,
            at: context.timestamp,
            builds: submit.builds,
            whatsNew: submit.whatsNew,
            releaseType: submit.releaseType,
            earliestReleaseDate: submit.earliestReleaseDate,
            listing: submit.listing,
            appReview: submit.appReview,
            screenshots: submit.screenshots,
            creative: submit.creative
        )
        let saved: SubmissionFile
        do {
            let message = "\(target.repo) の \(target.version) を審査に出す"
            saved = try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                guard Self.problem(submitting: submit, on: file, now: context.now()) == nil else { return false }
                file.submit = request
                // 前の取り下げは終わっている（新しく出し直す）
                file.withdrawal = nil
                if file.problem?.step == .submit { file.problem = nil }
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        guard saved.submit == request else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 載せるクリエイティブアセットが、承認した案に合わない理由。合えば nil
    static func problem(creative choice: SubmissionFile.CreativeChoice, on file: CreativeFile?) -> String? {
        guard let approved = file?.approved, approved.revision == choice.revision else {
            return "ヘッダーと検索結果の承認した案が変わった（見た案は \(choice.revision)）。見直してから送り直す"
        }
        guard let library = approved.library, library.total > 0, library.ready == library.total else {
            return "ヘッダーと検索結果の案 \(choice.revision) を、まだ App Store Connect のライブラリで置けない（取り込みを待つ）"
        }
        return nil
    }

    /// 人が確かめたスクショが、撮って比べた結果に合わない理由。合えば nil
    static func problem(screenshots decision: SubmissionFile.ScreenshotDecision, on file: SubmissionFile) -> String? {
        guard let captured = file.screenshots, captured.state == .captured, captured.commit == decision.commit else {
            return "スクショの撮影が人の見たものと違う（撮り直した・まだ撮っていない）。見直してから送り直す"
        }
        for reference in decision.keep {
            let shot = captured.sets.first { $0.displayType == reference.displayType && $0.locale == reference.locale }?
                .shots.first { $0.index == reference.index }
            guard shot?.changed == true else {
                return "前のままにするスクショ（\(reference.displayType)/\(reference.locale) の \(reference.index) 枚目）は、差のある画面でない"
            }
        }
        return nil
    }

    /// 受け付けられない理由。受け付けられれば nil
    static func problem(submitting submit: SubmitForReviewIntent, on file: SubmissionFile, now: Date) -> String? {
        if file.isEnded { return "\(file.version) のリリースはもう終わっている" }
        guard file.origin == .askhub else { return "\(file.version) は App Store Connect で手で審査に出した版。AskHub からは出せない" }
        if file.revision != submit.revision {
            return "\(file.version) の準備（ビルド・What's New・掲載文の案）が変わった（今の版は \(file.revision)）。見直してから送り直す"
        }
        guard file.awaitsSubmission else {
            return file.submit != nil || file.hasReviewInFlight ? "\(file.version) はもう審査に出している" : "\(file.version) の準備がまだそろっていない"
        }
        for choice in submit.builds where !file.builds.contains(where: { $0.platform == choice.platform && $0.build == choice.build }) {
            return "ビルド \(choice.platform.rawValue) (\(choice.build)) は、release ブランチから上げた最新のビルドでない"
        }
        let drafted = Set(file.whatsNew?.drafts.map(\.locale) ?? [])
        if Set(submit.whatsNew.map(\.locale)) != drafted {
            return drafted.isEmpty ? "初めての版は What's New を持たない" : "What's New の言語が下書き（\(drafted.sorted().joined(separator: "・"))）と違う"
        }
        let listed = Set(file.listing?.current.map(\.locale) ?? [])
        if let locale = submit.listing.map(\.locale).first(where: { !listed.contains($0) }) {
            return listed.isEmpty ? "初めての版の掲載文は App Store Connect で書く" : "掲載文の言語（\(locale)）が配信中の版に無い"
        }
        if submit.appReview != nil, file.appReview == nil { return "App Review の情報の案がまだ無い（初めての版は App Store Connect で書く）" }
        if let decision = submit.screenshots, let problem = Self.problem(screenshots: decision, on: file) { return problem }
        if let date = submit.earliestReleaseDate, date.date <= now { return "配信の日時が過ぎている" }
        return nil
    }
}

/// 配信する（`distributeRelease`）を受け付け、記録に写す。審査に通って配信を待っている版だけ。App Store Connect には見回りが送る
public struct DistributeReleaseHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let distribute: DistributeReleaseIntent
        do {
            distribute = try DistributeReleaseIntent(envelope: envelope)
        } catch {
            return .reject("配信する意図の形が違う（\(error.detail)）")
        }
        let target = distribute.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        if file.distribution?.approval == distribute.intent { return .accept }
        guard file.awaitsDistribution else {
            let reason = file.distribution != nil ? "の配信はもう受け付けている" : "は審査に通って配信を待つ状態でない"
            return .reject("\(target.version) \(reason)")
        }
        let request = SubmissionFile.Request(approval: distribute.intent, at: context.timestamp)
        return try await SubmissionRequests.record(path, message: "\(target.repo) の \(target.version) を配信する", in: context) { file in
            guard file.awaitsDistribution else { return false }
            file.distribution = request
            return true
        } check: { $0.distribution == request }
    }
}

/// 審査の取り下げ（`withdrawSubmission`）を受け付け、記録に写す。審査を待っている・審査中の版だけ。App Store Connect では見回りが取り下げる
public struct WithdrawSubmissionHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let withdraw: WithdrawSubmissionIntent
        do {
            withdraw = try WithdrawSubmissionIntent(envelope: envelope)
        } catch {
            return .reject("審査を取り下げる意図の形が違う（\(error.detail)）")
        }
        let target = withdraw.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        if file.withdrawal?.approval == withdraw.intent { return .accept }
        guard file.canWithdraw else { return .reject("\(target.version) は審査を待っている・審査中でない（取り下げられない）") }
        let request = SubmissionFile.Request(approval: withdraw.intent, at: context.timestamp)
        return try await SubmissionRequests.record(path, message: "\(target.repo) の \(target.version) の審査を取り下げる", in: context) { file in
            guard file.canWithdraw else { return false }
            file.withdrawal = request
            return true
        } check: { $0.withdrawal == request }
    }
}

/// 人が押した操作を記録に写す（読み直して確かめ、書けたかを確かめる）
enum SubmissionRequests {
    static func record(
        _ path: String,
        message: String,
        in context: CommanderContext,
        change: @escaping @Sendable (inout SubmissionFile) -> Bool,
        check: (SubmissionFile) -> Bool
    ) async throws(CommanderError) -> IntentDecision {
        let saved: SubmissionFile
        do {
            saved = try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                guard change(&file) else { return false }
                file.updatedAt = context.timestamp
                return true
            }.file
        } catch {
            throw .files(error)
        }
        // 読んだ後に状態が変わった。次の周で読み直して決める
        guard check(saved) else { throw .changedWhileProcessing(path) }
        return .accept
    }
}
