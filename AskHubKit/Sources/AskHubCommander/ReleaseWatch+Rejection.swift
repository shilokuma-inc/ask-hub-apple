import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CryptoKit
import Foundation

/// リジェクトの直し方の案（`docs/renewal/release.md` の「リジェクト」）。人が理由を貼ったら、常時オンの Mac の Claude（読むだけ）が、
/// release ブランチの写し・貼った文と画像・断られた版の今の掲載文を読んで、直し方の案を書く。ここで行うのは App Store Connect と GitHub の読み取りだけ
extension ReleaseWatch {
    /// 人が貼った理由に、直し方の案を書く。待てば書ける失敗（Claude の利用上限・障害）は書かずに次の見回りでやり直し、
    /// 書けない失敗は理由を記録に書いて人に選ばせる（人は理由を読んで直し方を選べる）
    func triageRejection(_ file: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        guard file.awaitsRejectionTriage, let rejection = file.rejection else { return file }
        let outcome: (triage: SubmissionFile.RejectionTriage?, failure: String?)
        do {
            outcome = (try await draftTriage(file, rejection: rejection, settings: settings), nil)
        } catch let problem as ReleaseStepProblem {
            guard problem.needsHuman else {
                report("\(file.repo) の \(file.version) のリジェクトの直し方の案を書けない（\(problem.message)）。次の見回りでやり直す")
                return file
            }
            outcome = (nil, problem.message)
        } catch {
            report("\(file.repo) の \(file.version) のリジェクトの直し方の案を書けない（\(error)）。次の見回りでやり直す")
            return file
        }
        do {
            let saved = try await saveTriage(outcome.triage, failure: outcome.failure, for: rejection.report, on: file)
            if let triage = outcome.triage {
                log("\(file.repo) の \(file.version) のリジェクトの直し方の案を書いた（\(triage.remedy.rawValue)）")
            } else {
                log("\(file.repo) の \(file.version) のリジェクトの直し方の案を書けなかった（\(outcome.failure ?? "")）")
            }
            return saved
        } catch {
            report("\(file.repo) の \(file.version) のリジェクトの直し方の案を記録に書けない（\(error)）。次の見回りでやり直す")
            return file
        }
    }

    private func draftTriage(
        _ file: SubmissionFile,
        rejection: SubmissionFile.Rejection,
        settings: RepositoryFile
    ) async throws -> SubmissionFile.RejectionTriage {
        guard let triager = rejections else {
            throw ReleaseStepProblem("リジェクトの直し方の案を書く仕組みが司令塔に無い。理由を読んで直し方を選ぶ", needsHuman: true)
        }
        guard let branch = file.branch else { throw ReleaseStepProblem("release ブランチが無い", needsHuman: true) }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        // 断られた版（どのプラットフォームも同じ文を出すので、最初のもの）の今の掲載文と App Review の情報
        let rejected = versions.first { $0.versionString == file.version.rawValue && $0.state.isRejected }
        var listing: [ListingText] = []
        if let rejected {
            // 言語の並びは読むたびに変わることがあるので、言語の順にそろえる
            listing = try await currentListing([rejected], firstVersion: false, store: store).sorted { $0.locale < $1.locale }
        }
        let review = try await reviewDetail(of: rejected, store: store)?.information
        let head = try await github { () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: branch.name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-rejection-\(ULID.generate().rawValue)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try await placeImages(of: rejection.report, in: directory)
        let material = RejectionMaterial(
            repo: file.repo,
            appName: app.name,
            version: file.version,
            commit: head ?? branch.commit,
            platforms: rejection.platforms,
            text: rejection.report.text,
            images: images,
            listing: listing,
            whatsNew: file.submit?.whatsNew ?? [],
            review: review,
            previous: (file.rejections ?? []).dropLast().compactMap { earlier in
                earlier.triage.map { "\($0.summary)（選んだ直し方: \(earlier.choice?.remedy.label ?? "選ばなかった")）" }
            }
        )
        let proposal: RejectionProposal
        do {
            proposal = try await triager.triage(material)
        } catch {
            throw ReleaseStepProblem(error.message, needsHuman: !error.retryable)
        }
        return Self.triage(proposal, material: material, readRejected: rejected != nil, at: context.timestamp)
    }

    /// 記録に書く案。掲載文と App Review の情報は、断られた版を読めたときだけ、今の文と一緒に持つ（出し直すシートの元にする）
    static func triage(
        _ proposal: RejectionProposal,
        material: RejectionMaterial,
        readRejected: Bool,
        at now: Timestamp
    ) -> SubmissionFile.RejectionTriage {
        let unchanged = "変えない"
        let listing = SubmissionFile.Listing(
            current: material.listing,
            drafts: proposal.listing,
            reason: proposal.listing.isEmpty ? unchanged : proposal.summary,
            draftedAt: now
        )
        let review = SubmissionFile.AppReview(
            current: material.review ?? ReviewInformation(),
            draft: proposal.review,
            reason: proposal.review == nil ? unchanged : proposal.summary,
            draftedAt: now
        )
        return SubmissionFile.RejectionTriage(
            remedy: proposal.remedy,
            summary: proposal.summary,
            plan: proposal.plan,
            request: proposal.request,
            listing: readRejected ? listing : nil,
            whatsNew: proposal.whatsNew.isEmpty ? nil : proposal.whatsNew,
            appReview: readRejected ? review : nil,
            reply: proposal.reply,
            draftedAt: now
        )
    }

    /// 人が貼った画像を、署名した封筒と合うか確かめてから一時フォルダに置く（Claude が Read で読む）
    private func placeImages(of report: SubmissionFile.RejectionReport, in directory: URL) async throws -> [URL] {
        guard !report.attachments.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for attachment in report.attachments {
            let path = StatePath.attachment(device: report.approval.keyId, nonce: report.approval.nonce, number: attachment.number)
            let data: Data?
            do {
                data = try await context.store.read(path)?.data
            } catch {
                throw ReleaseStepProblem("貼った画像を読めない（\(error)）", needsHuman: false)
            }
            guard let data, data.count == attachment.size,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else {
                throw ReleaseStepProblem("貼った画像 \(attachment.number)（\(attachment.name)）が無いか、理由と合わない。貼り直す", needsHuman: true)
            }
            // 名前は人が付けたものなので、番号だけのファイル名にして、拡張子だけを残す
            let suffix = URL(fileURLWithPath: attachment.name).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let url = directory.appendingPathComponent("\(attachment.number)" + (suffix.isEmpty ? "" : ".\(suffix)"))
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// 案（か書けなかった理由）を、同じ理由の対処に書く。読んだ後に人が貼り直していれば書かない
    nonisolated private func saveTriage(
        _ triage: SubmissionFile.RejectionTriage?,
        failure: String?,
        for report: SubmissionFile.RejectionReport,
        on file: SubmissionFile
    ) async throws(CommanderError) -> SubmissionFile {
        let path = StatePath.submission(file.repo, file.version)
        let message = "\(file.repo) の \(file.version) のリジェクトの直し方の案"
        let now = context.timestamp
        return try await context.writingResult { () throws(CommanderError) -> SubmissionFile in
            do throws(StateFileStore.Failure) {
                return try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                    guard file.awaitsRejectionTriage, var rejections = file.rejections, var rejection = rejections.last,
                          rejection.report == report else { return false }
                    rejection.triage = triage
                    rejection.failure = failure
                    rejections[rejections.count - 1] = rejection
                    file.rejections = rejections
                    file.updatedAt = now
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }
}
