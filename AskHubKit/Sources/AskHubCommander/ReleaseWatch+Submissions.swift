import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// リリースを始めた版の準備（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 2〜5）。
/// release ブランチ → develop の版を上げる PR → What's New の下書き → 掲載文の案 → release ブランチから上げたビルド、の順に進め、進めるたびに
/// `submissions/<版>.json` に書く。ここで行うのは GitHub の操作と App Store Connect の読み取りだけ（書き込みは人の意図を受け付けてから）
extension ReleaseWatch {
    /// 終わっていない、リリースを始めた版の記録を進め、進めた後の記録を返す
    @discardableResult
    func advanceSubmissions(_ repo: RepositoryFullName, settings: RepositoryFile) async -> [SubmissionFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.list(StatePath.submissions(repo)) ?? []
        } catch {
            report("\(repo) のリリースの記録を並べられない（\(error)）。次の見回りでやり直す")
            return []
        }
        let versions = entries.filter { $0.kind == .file && $0.name.hasSuffix(".json") }
            .compactMap { MarketingVersion(rawValue: String($0.name.dropLast(".json".count))) }
            .sorted()
        var advanced: [SubmissionFile] = []
        for version in versions {
            guard let file = try? await context.readable(SubmissionFile.self, at: StatePath.submission(repo, version)) else { continue }
            guard !file.isEnded else {
                // やめた版は、まだ審査に出していない App Store Connect の版の枠を消す。消せなかった枠を知らせる間は返す
                if file.end?.reason == .abandoned {
                    if file.awaitsSlotRemoval {
                        advanced.append(await submissionStep(.appStoreVersion, file) { try await self.removeSlots($0, settings: settings) })
                    } else if file.appStoreVersions?.contains(where: { $0.removal == .kept }) == true {
                        advanced.append(file)
                    }
                    continue
                }
                // 配信した版は、release ブランチを main と develop に取り込み、配信の知らせを出し続ける間は返す
                guard file.end?.reason == .distributed else { continue }
                let bases = Self.integrationBases(settings)
                advanced.append(file.awaitsIntegration(bases: bases) ? await integrate(file, settings: settings) : file)
                continue
            }
            var progressed = await performRequests(file, settings: settings)
            if progressed.origin == .askhub { progressed = await prepare(progressed, settings: settings) }
            advanced.append(progressed)
        }
        return advanced
    }

    /// 1 つの版の準備を、進められるところまで進める
    func prepare(_ submission: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        var file = submission
        // App Store Connect の版の枠は、リリースを始めたらすぐ作る（スクショや説明文を先に直せるように）。審査に出した後は、提出の段取りに任せる
        if file.appStoreVersions != nil, file.submit == nil, !file.hasReviewInFlight, !isHeld(.appStoreVersion, file) {
            file = await submissionStep(.appStoreVersion, file) { try await self.syncSlots($0, settings: settings) }
        }
        if file.branch == nil, !isHeld(.branch, file) {
            file = await submissionStep(.branch, file) { try await self.createReleaseBranch($0, settings: settings) }
        }
        // develop の版は、release ブランチを作ってから上げる（release ブランチに今の版を残す）
        guard file.branch != nil else { return file }
        if file.nextVersion?.state != .merged, file.nextVersion?.state != .skipped, !isHeld(.nextVersion, file) {
            file = await submissionStep(.nextVersion, file) { file in
                let reason = "\(file.version) のリリースを始めた（release ブランチ `\(SubmissionFile.branchName(for: file.version))` を作った）ので"
                guard let next = try await self.nextVersionStep(
                    file.repo, version: file.version, current: file.nextVersion, settings: settings, reason: reason
                ) else { return nil }
                var file = file
                file.nextVersion = next
                return file
            }
        }
        if file.whatsNew == nil, !isHeld(.whatsNew, file) {
            file = await submissionStep(.whatsNew, file) { try await self.draftWhatsNew($0, settings: settings) }
        }
        // 審査に出した後は、案を作らない（出した中身は submit にある）
        if file.listing == nil, file.submit == nil, !file.hasReviewInFlight, !isHeld(.listing, file) {
            file = await submissionStep(.listing, file) { try await self.draftListing($0, settings: settings) }
        }
        // スクショは見回りの外で撮る（UI テストは長い）
        if file.submit == nil, !file.hasReviewInFlight, !isHeld(.screenshots, file) {
            file = await prepareScreenshots(file, settings: settings)
        }
        // 審査に出した後は、出したビルドを変えない（出し直すときは取り下げてから）
        if file.submit == nil, !file.hasReviewInFlight, !isHeld(.builds, file) {
            file = await submissionStep(.builds, file) { try await self.findBuilds($0, settings: settings) }
        }
        // 見つけたビルドと下書きを、この見回りのうちに枠に入れる
        if file.appStoreVersions?.isEmpty == false, file.submit == nil, !file.hasReviewInFlight, !isHeld(.appStoreVersion, file) {
            file = await submissionStep(.appStoreVersion, file) { try await self.syncSlots($0, settings: settings) }
        }
        return file
    }

    // MARK: - 2. release ブランチ

    func createReleaseBranch(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        var file = file
        let base = settings.build?.baseBranch ?? "develop"
        let name = SubmissionFile.branchName(for: file.version)
        if let existing = try await github({ () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: name) }) {
            log("\(file.repo) の \(name) は前からあるので、そのまま使う")
            file.branch = .init(name: name, commit: existing, created: false, at: context.timestamp)
            return file
        }
        guard let head = try await github({ () throws(PullRequestError) in try await hosting.branchHead(file.repo, branch: base) }) else {
            throw ReleaseStepProblem("\(base) ブランチが無い。リポジトリのビルドの設定（base）を確かめる", needsHuman: true)
        }
        let created = try await github { () throws(PullRequestError) in try await hosting.createBranch(file.repo, branch: name, at: head) }
        log("\(file.repo) の \(base)（\(head.prefix(7))）から \(name) を作った")
        file.branch = .init(name: name, commit: created, created: created == head, at: context.timestamp)
        return file
    }

    // MARK: - 4. What's New

    /// 配信中の版の掲載文の言語ごとに下書きする。配信中の版が無ければ初めての版なので、下書きしない（空の下書き）
    func draftWhatsNew(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard let branch = file.branch else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        var file = file
        guard let current = Self.liveVersion(versions) else {
            log("\(file.repo) は App Store に配信中の版が無いので、\(file.version) の What's New は下書きしない（初めての版）")
            file.whatsNew = .init(drafts: [], draftedAt: context.timestamp)
            return file
        }
        let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.localizations(of: current.id) }
        let locales = localizations.map(\.locale)
        guard !locales.isEmpty else {
            throw ReleaseStepProblem("配信中の版（\(current.versionString)）の掲載文の言語を読めない", needsHuman: true)
        }
        guard let drafter = whatsNew else {
            throw ReleaseStepProblem("What's New を下書きする仕組みが司令塔に無い", needsHuman: true)
        }
        let (changes, epics) = try await changeMaterial(file, upTo: branch.commit)
        let material = WhatsNewMaterial(
            repo: file.repo,
            appName: app.name,
            version: file.version,
            commit: branch.commit,
            changes: changes,
            epics: epics,
            locales: locales
        )
        let drafts: [LocalizedText]
        do {
            drafts = try await drafter.draft(material)
        } catch {
            throw ReleaseStepProblem(error.message, needsHuman: !error.retryable)
        }
        log("\(file.repo) の \(file.version) の What's New を下書きした（\(locales.joined(separator: "・"))）")
        file.whatsNew = .init(drafts: drafts, draftedAt: context.timestamp)
        return file
    }

    // MARK: - 4. 掲載文

    /// 配信中の版の掲載文（説明文・キーワード・プロモーションテキスト）を、変更をもとに言語ごとに直す案を書く。
    /// 配信中の版が無ければ初めての版なので、案を書かない（今の文も案も空）
    func draftListing(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard let branch = file.branch else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        var file = file
        guard let live = Self.liveVersion(versions) else {
            log("\(file.repo) は App Store に配信中の版が無いので、\(file.version) の掲載文の案は書かない（初めての版）")
            file.listing = .init(current: [], drafts: [], reason: "初めての版なので、掲載文は App Store Connect で書きます", draftedAt: context.timestamp)
            return file
        }
        let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.localizations(of: live.id) }
        let current = localizations.map(\.listing)
        guard !current.isEmpty else {
            throw ReleaseStepProblem("配信中の版（\(live.versionString)）の掲載文の言語を読めない", needsHuman: true)
        }
        guard let drafter = listing else {
            throw ReleaseStepProblem("掲載文の案を書く仕組みが司令塔に無い", needsHuman: true)
        }
        // App Review の情報（パスワードと連絡先は読まない）。まだ無ければ、空の今の情報として案を書く
        let review = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.reviewDetail(of: live.id) }
        let (changes, epics) = try await changeMaterial(file, upTo: branch.commit)
        let material = ListingMaterial(
            repo: file.repo,
            appName: app.name,
            version: file.version,
            commit: branch.commit,
            changes: changes,
            epics: epics,
            current: current,
            review: review?.information
        )
        let proposal: ListingProposal
        do {
            proposal = try await drafter.draft(material)
        } catch {
            throw ReleaseStepProblem(error.message, needsHuman: !error.retryable)
        }
        let locales = proposal.drafts.map(\.locale)
        log("\(file.repo) の \(file.version) の掲載文の案を書いた（\(locales.isEmpty ? "変えない" : locales.joined(separator: "・"))）")
        file.listing = .init(current: current, drafts: proposal.drafts, reason: proposal.reason, draftedAt: context.timestamp)
        file.appReview = .init(
            current: review?.information ?? ReviewInformation(),
            draft: proposal.review,
            reason: proposal.reviewReason.flatMap { $0.isEmpty ? nil : $0 } ?? "審査する人に伝えることは変わらないので、変えません",
            draftedAt: context.timestamp
        )
        return file
    }

    /// 配信中の版（iOS を先に見る。掲載文の言語はプラットフォームごとにあるが、ふつうは同じ）。無ければ初めての版
    static func liveVersion(_ versions: [AppStoreVersionInfo]) -> AppStoreVersionInfo? {
        versions.filter { $0.state == .readyForDistribution }
            .min { ($0.platform == .iOS ? 0 : 1) < ($1.platform == .iOS ? 0 : 1) }
    }

    /// 前に配信した版のタグから release ブランチの先頭までの変更と、その間にマージした epic
    private func changeMaterial(
        _ file: SubmissionFile,
        upTo commit: String
    ) async throws -> (ReleaseChanges, [ReleaseNotesMaterial.Epic]) {
        let changes: ReleaseChanges
        do {
            changes = try await sources.changes(file.repo, upTo: commit, below: file.version)
        } catch {
            throw ReleaseStepProblem("release ブランチまでの変更を読めない（\(error)）", needsHuman: false)
        }
        let commits = Set(changes.changes.map(\.commit))
        let epics = try await context.epics(of: file.repo) { epic in epic.merge.map { commits.contains($0.commit) } ?? false }
            .sorted { $0.id < $1.id }
            .map { ReleaseNotesMaterial.Epic(title: $0.title, summary: $0.summary) }
        return (changes, epics)
    }

    // MARK: - 5. ビルド

    /// release ブランチを作った後に上げて、処理を終えたビルドのうち、プラットフォームごとに最新のもの
    func findBuilds(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard let branch = file.branch else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let builds = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.builds(of: app.id, version: file.version)
        }
        var latest: [SubmissionFile.Build] = []
        var unanswered: [String] = []
        // 新しく上げた順に返るので、プラットフォームごとに最初のものを使う
        for build in builds where !build.expired && (build.uploadedAt.map { $0 >= branch.at.date } ?? false) {
            guard !latest.contains(where: { $0.platform == build.platform }) else { continue }
            guard build.usesNonExemptEncryption != nil else {
                // 輸出コンプライアンスは法令の申告なので、司令塔は代わりに答えない
                unanswered.append("\(build.platform.rawValue) (\(build.number))")
                continue
            }
            latest.append(.init(platform: build.platform, build: build.number, uploadedAt: build.uploadedAt.map(Timestamp.init)))
        }
        if latest.isEmpty, !unanswered.isEmpty {
            throw ReleaseStepProblem(
                "ビルド \(unanswered.joined(separator: "・")) の輸出コンプライアンスに答えていない。App Store Connect の TestFlight で答える"
                    + "（Info.plist に ITSAppUsesNonExemptEncryption を入れると、次から聞かれない）",
                needsHuman: true
            )
        }
        guard latest != file.builds else { return nil }
        var file = file
        file.builds = latest
        log("\(file.repo) の \(file.version) のビルド（\(latest.map { "\($0.platform.rawValue) (\($0.build))" }.joined(separator: "・"))）を見つけた")
        return file
    }

    // MARK: - 共通

    /// リポジトリのアプリと、それを読める鍵。鍵が無い・アプリが見つからなければ、待てば直らない問題にする
    func submissionApp(
        _ repo: RepositoryFullName,
        settings: RepositoryFile
    ) async throws -> (store: any AppStoreConnectSubmitting, app: AppStoreApp) {
        guard !stores.isEmpty else {
            throw ReleaseStepProblem("App Store Connect の鍵が司令塔に無い（askhub-commander app-store-connect で入れる）", needsHuman: true)
        }
        let found: (store: Int, app: AppStoreApp)?
        do {
            found = try await app(of: repo, base: settings.build?.baseBranch)
        } catch let error as AppStoreConnectError {
            throw Self.problem(error)
        } catch {
            throw ReleaseStepProblem("App Store Connect のアプリを探せない（\(error)）", needsHuman: false)
        }
        guard let found else {
            throw ReleaseStepProblem("\(repo) のアプリが、どの鍵の App Store Connect にも見つからない", needsHuman: true)
        }
        return (stores[found.store], found.app)
    }

    /// App Store Connect の操作。待てば直る失敗はそのまま投げ、人が直す失敗は `ReleaseStepProblem` にする
    func appStoreConnect<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw Self.problem(error)
        }
    }

    static func problem(_ error: AppStoreConnectError) -> ReleaseStepProblem {
        switch error {
        case .rateLimited, .unavailable, .malformed:
            ReleaseStepProblem("\(error)", needsHuman: false)
        case .keyUnavailable, .unauthorized, .refused:
            ReleaseStepProblem("\(error)", needsHuman: true)
        }
    }

    /// 人が直す問題を書いてから、まだ試し直さない区切りか（What's New と掲載文は Claude を呼ぶので長く空ける）
    private func isHeld(_ step: SubmissionFile.Step, _ file: SubmissionFile) -> Bool {
        guard let problem = file.problem, problem.step == step, problem.needsHuman else { return false }
        let interval: TimeInterval = step == .whatsNew || step == .listing ? 6 * 60 * 60 : 30 * 60
        return context.now().timeIntervalSince(problem.at.date) < interval
    }

    /// 1 つの区切り。進めたら記録を書き直したものを返す。進められなければ `problem` に書く（同じ理由なら書き直さない）
    func submissionStep(
        _ step: SubmissionFile.Step,
        _ file: SubmissionFile,
        _ body: (SubmissionFile) async throws -> SubmissionFile?
    ) async -> SubmissionFile {
        do {
            guard let changed = try await body(file) else { return file }
            return try await saveSubmission(changed, step: step)
        } catch let problem as ReleaseStepProblem {
            report("\(file.repo) の \(file.version) のリリース（\(step.rawValue)）を進められない: \(problem.message)")
            let failure = SubmissionFile.Problem(
                step: step, message: problem.message, needsHuman: problem.needsHuman, at: context.timestamp
            )
            return (try? await saveSubmissionProblem(failure, on: file)) ?? file
        } catch {
            report("\(file.repo) の \(file.version) のリリース（\(step.rawValue)）を進められない: \(error)。次の見回りでやり直す")
            return file
        }
    }

    /// 区切りが進めた欄を、今の記録に足して書く（人の意図が同じ記録に書いたものを消さない）。ビルド・What's New・掲載文の案が変われば `revision` を上げる
    nonisolated func saveSubmission(_ changed: SubmissionFile, step: SubmissionFile.Step) async throws(CommanderError) -> SubmissionFile {
        let path = StatePath.submission(changed.repo, changed.version)
        let message = "\(changed.repo) の \(changed.version) のリリース（\(step.rawValue)）"
        return try await context.writingResult { () throws(CommanderError) -> SubmissionFile in
            do throws(StateFileStore.Failure) {
                return try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                    // やめた後に進めたものは書かない（配信した後の取り込み・やめた版の枠を消すのほか）
                    let afterEnd = (step == .integration && file.end?.reason == .distributed)
                        || (step == .appStoreVersion && file.end?.reason == .abandoned)
                    guard !file.isEnded || afterEnd else { return false }
                    let before = file
                    Self.merge(changed, into: &file, step: step)
                    if file.problem?.step == step { file.problem = nil }
                    guard file != before else { return false }
                    file.updatedAt = context.timestamp
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }

    /// 区切りが進めた欄だけを、今の記録に写す
    static func merge(_ changed: SubmissionFile, into file: inout SubmissionFile, step: SubmissionFile.Step) {
        switch step {
        case .branch:
            if file.branch == nil { file.branch = changed.branch }
        case .nextVersion:
            if file.nextVersion?.state != .merged { file.nextVersion = changed.nextVersion }
        case .whatsNew, .listing, .builds:
            mergePreparation(changed, into: &file, step: step)
        case .submit, .distribute, .withdraw, .review:
            mergeRequests(changed, into: &file, step: step)
        case .integration, .appStoreVersion:
            mergeAppStoreSide(changed, into: &file, step: step)
        case .screenshots:
            mergeScreenshots(changed, into: &file)
        }
    }

    /// 人が確かめる準備（What's New の下書き・掲載文の案・ビルド）を写し、変わったら `revision` を上げる。審査に出した後は変えない
    static func mergePreparation(_ changed: SubmissionFile, into file: inout SubmissionFile, step: SubmissionFile.Step) {
        switch step {
        case .whatsNew:
            guard file.whatsNew == nil, let whatsNew = changed.whatsNew else { return }
            file.whatsNew = whatsNew
        case .listing:
            guard file.listing == nil, file.submit == nil, let listing = changed.listing else { return }
            file.listing = listing
            file.appReview = changed.appReview
        case .builds:
            guard file.submit == nil, file.builds != changed.builds else { return }
            file.builds = changed.builds
        default:
            return
        }
        file.revision += 1
    }

    /// 配信した後の取り込みと、App Store Connect の版の枠を写す
    static func mergeAppStoreSide(_ changed: SubmissionFile, into file: inout SubmissionFile, step: SubmissionFile.Step) {
        if step == .integration {
            file.integration = changed.integration
        } else {
            mergeSlots(changed, into: &file)
        }
    }

    /// 枠を写す。今の記録で消した・消さなかった枠は、その結果を残す（枠を入れる見回りと、やめた後の消すが重ならないように）
    static func mergeSlots(_ changed: SubmissionFile, into file: inout SubmissionFile) {
        guard var slots = changed.appStoreVersions else { return }
        for index in slots.indices {
            guard let current = file.appStoreVersions?.first(where: { $0.platform == slots[index].platform }), current.removal != nil else {
                continue
            }
            slots[index].removal = current.removal
            slots[index].removalNote = current.removalNote
        }
        file.appStoreVersions = slots
    }

    /// 人が押した操作を送った結果を写す。記録を読んだ後に、人がほかの操作を押していれば写さない
    static func mergeRequests(_ changed: SubmissionFile, into file: inout SubmissionFile, step: SubmissionFile.Step) {
        switch step {
        case .submit:
            // 同じ「審査に出す」のままなら、出し終えたプラットフォームの状態を写す
            guard file.submit == changed.submit else { return }
            for review in changed.review where review.submittedAt != nil {
                guard file.review.first(where: { $0.platform == review.platform }) != review else { continue }
                file.review.removeAll { $0.platform == review.platform }
                file.review.append(review)
            }
        case .distribute:
            if file.distribution?.approval == changed.distribution?.approval, file.distribution?.doneAt == nil {
                file.distribution?.doneAt = changed.distribution?.doneAt
            }
        case .withdraw:
            guard file.withdrawal?.approval == changed.withdrawal?.approval, file.withdrawal?.doneAt == nil,
                  changed.withdrawal?.doneAt != nil else { return }
            file.withdrawal = changed.withdrawal
            file.submit = nil
        default:
            break
        }
    }

    nonisolated func saveSubmissionProblem(
        _ problem: SubmissionFile.Problem,
        on file: SubmissionFile
    ) async throws(CommanderError) -> SubmissionFile {
        let path = StatePath.submission(file.repo, file.version)
        let message = "\(file.repo) の \(file.version) のリリースを進められない"
        return try await context.writingResult { () throws(CommanderError) -> SubmissionFile in
            do throws(StateFileStore.Failure) {
                return try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                    guard !file.isEnded || problem.step == .integration || problem.step == .appStoreVersion else { return false }
                    // 人が直す問題がほかの区切りに残っていれば、先に書いたほうを残す
                    if let current = file.problem, current.needsHuman, current.step != problem.step { return false }
                    if let current = file.problem, current.step == problem.step, current.needsHuman == problem.needsHuman,
                       !problem.needsHuman || current.message == problem.message {
                        return false
                    }
                    file.problem = problem
                    file.updatedAt = context.timestamp
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }
}
