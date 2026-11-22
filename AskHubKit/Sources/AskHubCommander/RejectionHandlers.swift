import AskHubProtocol
import AskHubStateStore
import Foundation

// 審査で断られた（リジェクト）ときの人の意図の処理（`docs/renewal/release.md` の「リジェクト」）。
// どれも `submissions/<版>.json` に写すだけで、Claude の案と App Store Connect への出し直しは見回り（`ReleaseWatch`）が行う

/// リジェクトの理由を貼る（`reportRejection`）を受け付け、今の断られた提出の対処に写す。直し方を選ぶ前なら貼り直せる（案を書き直す）
public struct ReportRejectionHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let report: ReportRejectionIntent
        do {
            report = try ReportRejectionIntent(envelope: envelope)
        } catch {
            return .reject("リジェクトの理由の意図の形が違う（\(error.detail)）")
        }
        let target = report.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        // 前の周で写した（やり直し）
        if file.rejection?.report.approval == report.intent { return .accept }
        if let problem = Self.problem(reporting: file) { return .reject(problem) }
        // 添付は確かめること（protocol.md の 3）なので、合わなければ記録を書かずに残す（置き直せば次の周で受け付ける）
        if let problem = try await RequestHandler.attachmentProblem(report.attachments, of: report.intent, in: context) {
            return .ignore(problem)
        }
        let recorded = SubmissionFile.RejectionReport(
            text: report.text, attachments: report.attachments, approval: report.intent, at: context.timestamp
        )
        return try await SubmissionRequests.record(path, message: "\(target.repo) の \(target.version) のリジェクトの理由", in: context) { file in
            guard Self.problem(reporting: file) == nil, let submit = file.submit else { return false }
            let platforms = file.review.filter { $0.state.isRejected }.map(\.platform)
            var rejections = file.rejections ?? []
            if let last = rejections.last, last.submittedAt == submit.at {
                // 直し方を選ぶ前の貼り直し。前の案は捨てて書き直させる
                rejections[rejections.count - 1] = .init(submittedAt: submit.at, platforms: platforms, report: recorded)
            } else {
                rejections.append(.init(submittedAt: submit.at, platforms: platforms, report: recorded))
            }
            file.rejections = rejections
            return true
        } check: { $0.rejection?.report == recorded }
    }

    /// 理由を貼れない理由。貼れれば nil
    static func problem(reporting file: SubmissionFile) -> String? {
        if file.isEnded { return "\(file.version) のリリースはもう終わっている" }
        guard file.origin == .askhub else { return "\(file.version) は App Store Connect で手で審査に出した版。AskHub で出した版だけを扱う" }
        guard file.isRejected else { return "\(file.version) は審査で断られていない" }
        guard file.canReportRejection else {
            return file.submit == nil ? "\(file.version) は審査に出した中身が無い（直し方をもう選んだ）" : "\(file.version) の直し方はもう選んだ"
        }
        return nil
    }
}

/// リジェクトの直し方を選ぶ（`resolveRejection`）を受け付け、記録に写す。審査に出す中身を消し、人が確かめて出し直せるようにする。
/// 出し直すシートの元（What's New・掲載文・App Review の情報）は、断られた版の今の文と、メタデータを直すなら Claude の案にする
public struct ResolveRejectionHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let resolve: ResolveRejectionIntent
        do {
            resolve = try ResolveRejectionIntent(envelope: envelope)
        } catch {
            return .reject("リジェクトの直し方の意図の形が違う（\(error.detail)）")
        }
        let target = resolve.target
        let path = StatePath.submission(target.repo, target.version)
        guard let file = try await context.read(SubmissionFile.self, at: path) else {
            return .reject("\(target.repo) の \(target.version) のリリースの記録が無い")
        }
        if file.rejection?.choice?.approval == resolve.intent { return .accept }
        if let problem = Self.problem(resolving: file) { return .reject(problem) }
        let choice = SubmissionFile.RejectionChoice(remedy: resolve.remedy, approval: resolve.intent, at: context.timestamp)
        let message = "\(target.repo) の \(target.version) のリジェクトの直し方（\(resolve.remedy.rawValue)）"
        return try await SubmissionRequests.record(path, message: message, in: context) { file in
            guard Self.problem(resolving: file) == nil else { return false }
            Self.apply(choice, to: &file, at: context.timestamp)
            return true
        } check: { $0.rejection?.choice == choice }
    }

    static func problem(resolving file: SubmissionFile) -> String? {
        if file.isEnded { return "\(file.version) のリリースはもう終わっている" }
        guard file.awaitsRejectionChoice else {
            if file.rejection?.choice != nil, file.submit == nil { return "\(file.version) の直し方はもう選んだ" }
            return file.awaitsRejectionTriage ? "\(file.version) の直し方の案をまだ書いている" : "\(file.version) は直し方を選べる状態でない"
        }
        return nil
    }

    /// 選んだ直し方を写す。審査に出した中身を消し（出し直せる）、出し直すシートの元を、断られた版の今の文と Claude の案にする
    static func apply(_ choice: SubmissionFile.RejectionChoice, to file: inout SubmissionFile, at now: Timestamp) {
        guard var rejections = file.rejections, var rejection = rejections.last, let submit = file.submit else { return }
        rejection.choice = choice
        rejections[rejections.count - 1] = rejection
        file.rejections = rejections
        let triage = rejection.triage
        let metadata = choice.remedy == .metadata
        // What's New は人が前に確かめた文を元にし、メタデータを直すなら Claude の案で言語ごとに置き換える
        var whatsNew = submit.whatsNew
        if metadata {
            for draft in triage?.whatsNew ?? [] {
                if let index = whatsNew.firstIndex(where: { $0.locale == draft.locale }) { whatsNew[index] = draft }
            }
        }
        if file.whatsNew != nil { file.whatsNew = .init(drafts: whatsNew, draftedAt: now) }
        let unchanged = "リジェクトの直し方に「\(choice.remedy.label)」を選んだので、断られた版の文のまま"
        if let listing = triage?.listing {
            file.listing = .init(
                current: listing.current,
                drafts: metadata ? listing.drafts : [],
                reason: metadata ? listing.reason : unchanged,
                draftedAt: now
            )
        }
        if let review = triage?.appReview {
            file.appReview = .init(
                current: review.current,
                draft: metadata ? review.draft : nil,
                reason: metadata ? review.reason : unchanged,
                draftedAt: now
            )
        }
        file.submit = nil
        file.withdrawal = nil
        if file.problem?.step == .submit { file.problem = nil }
        file.revision += 1
    }
}

extension SubmissionFile.RejectionRemedy {
    /// 人が読む名前
    public var label: String {
        switch self {
        case .code: "コードを直す"
        case .metadata: "メタデータだけ直す"
        case .reply: "返信だけで済む"
        }
    }
}
