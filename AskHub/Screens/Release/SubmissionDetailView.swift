import SwiftUI

/// リリースを始めた版の準備と審査。準備がそろったら What's New とビルドを確かめて審査に出し、審査に通ったら配信する。
/// 審査を待っている・審査中なら取り下げ、出す前・取り下げた後・断られた後ならやめられる
struct SubmissionDetailView: View {
    let repositoryID: TargetRepository.ID
    let version: String

    @Environment(ClientStore.self) private var store
    @State private var isSubmitting = Self.initialSubmitting
    @State private var confirming: Confirmation?
    @State private var isRetaking = false

    /// 撮影では、起動引数で審査に出すシートを開いておく
    private static var initialSubmitting: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .submitReview
        #else
        false
        #endif
    }

    /// 取り消しにくい操作の確かめ
    private enum Confirmation: String, Identifiable {
        case distribute
        case withdraw
        case abandon

        var id: String { rawValue }
    }

    var body: some View {
        if let submission = store.snapshot?.submission(Submission.id(repositoryID, version)) {
            content(submission)
        } else {
            ContentUnavailableView("このリリースは見つかりません", systemImage: "shippingbox")
        }
    }

    private func content(_ submission: Submission) -> some View {
        List {
            CardSection {
                AppHeaderView(repository: store.repository(submission.repositoryID), iconSize: 40) {
                    Text(submission.startedInAskHub ? "リリース \(submission.version)" : "\(submission.version)（App Store Connect で審査に出した版）")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                // 操作を送った後に、司令塔がしばらく受け取っていない・断ったときの理由
                ReflectionStatusView(target(submission))
            }
            actions(submission)
            CardSection {
                ForEach(submission.steps) { step in
                    StepStatusRow(title: step.title, detail: step.detail, state: step.state)
                }
            } header: {
                Text("進み具合")
            } footer: {
                Text(submission.startedInAskHub
                    ? "司令塔が順に進めます。App Store Connect に書くのは、あなたが審査に出す・配信する・取り下げを押したときだけです"
                    : "App Store Connect で手で審査に出した版です。審査の状態を 30 分ごとに読み、変わったら知らせます")
            }
            whatsNewSection(submission)
            listingSection(submission)
            appReviewSection(submission)
            links(submission)
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("\(submission.version) のリリース")
        .sheet(isPresented: $isRetaking) {
            if let screenshots = submission.screenshots {
                RetakeScreenshotsSheet(screenshots: screenshots) { displayTypes, locales in
                    isRetaking = false
                    let id = submission.repositoryID
                    send(.retakeScreenshots(repositoryID: id, version: submission.version, displayTypes: displayTypes, locales: locales))
                } onClose: {
                    isRetaking = false
                }
            }
        }
        .sheet(isPresented: $isSubmitting) {
            SubmitReviewSheet(submission: submission) { isSubmitting = false }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { action in
            confirmationButton(action, submission: submission)
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    private func target(_ submission: Submission) -> IntentTarget {
        .submission(repositoryID: submission.repositoryID, version: submission.version)
    }

    // MARK: - 操作

    @ViewBuilder private func actions(_ submission: Submission) -> some View {
        let id = submission.repositoryID
        let probe = Submission.SubmitRequest(revision: submission.revision, builds: [], whatsNew: [], releaseType: .afterApproval)
        let canSubmit = submission.awaitsSubmission && submission.sending == nil
            && store.supports(.submitForReview(repositoryID: id, version: submission.version, request: probe))
        let canDistribute = submission.awaitsDistribution && submission.sending == nil
            && store.supports(.distributeRelease(repositoryID: id, version: submission.version))
        let canWithdraw = submission.canWithdraw && submission.sending == nil
            && store.supports(.withdrawSubmission(repositoryID: id, version: submission.version))
        let canAbandon = submission.canAbandon && submission.sending == nil
            && store.supports(.abandonRelease(repositoryID: id, version: submission.version))
        let canRetake = submission.canRetakeScreenshots && submission.sending == nil && submission.screenshots?.sets.isEmpty == false
            && store.supports(.retakeScreenshots(repositoryID: id, version: submission.version, displayTypes: [], locales: []))
        if canSubmit || canDistribute || canWithdraw || canAbandon || canRetake {
            CardSection {
                if canSubmit {
                    Button("確かめて審査に出す…", systemImage: "paperplane") { isSubmitting = true }
                        .accessibilityIdentifier("submission-submit")
                }
                if canDistribute {
                    Button("配信する…", systemImage: "shippingbox") { confirming = .distribute }
                        .accessibilityIdentifier("submission-distribute")
                }
                if canWithdraw {
                    Button("審査を取り下げる…", systemImage: "arrow.uturn.backward") { confirming = .withdraw }
                        .accessibilityIdentifier("submission-withdraw")
                }
                if canRetake {
                    Button("スクショを撮り直す…", systemImage: "camera.rotate") { isRetaking = true }
                        .accessibilityIdentifier("submission-retake-screenshots")
                }
                if canAbandon {
                    Button("このリリースをやめる…", systemImage: "xmark.circle", role: .destructive) { confirming = .abandon }
                        .accessibilityIdentifier("submission-abandon")
                }
            } header: {
                Text("あなたの番")
            }
            .disabled(store.isReflecting([target(submission)]))
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding { confirming != nil } set: { if !$0 { confirming = nil } }
    }

    private var confirmationTitle: String {
        switch confirming {
        case .distribute: "App Store で配信しますか？"
        case .withdraw: "審査を取り下げますか？"
        case .abandon: "このリリースをやめますか？"
        case nil: ""
        }
    }

    private func confirmationMessage(_ action: Confirmation) -> String {
        switch action {
        case .distribute: "配信すると取り消せません。24 時間ほどで App Store に出ます"
        case .withdraw: "審査の待ちの順番は失われます。取り下げた後は、ビルドや What's New を直して審査に出し直せます"
        case .abandon: "記録を終わりにするだけで、release ブランチと App Store Connect の版は残します。次のリリースを始められるようになります"
        }
    }

    @ViewBuilder private func confirmationButton(_ action: Confirmation, submission: Submission) -> some View {
        let id = submission.repositoryID
        switch action {
        case .distribute:
            Button("配信する") { send(.distributeRelease(repositoryID: id, version: submission.version)) }
        case .withdraw:
            Button("取り下げる", role: .destructive) { send(.withdrawSubmission(repositoryID: id, version: submission.version)) }
        case .abandon:
            Button("やめる", role: .destructive) { send(.abandonRelease(repositoryID: id, version: submission.version)) }
        }
    }

    private func send(_ intent: HumanIntent) {
        Task { await store.send(intent) }
    }

    // MARK: - What's New・リンク

    @ViewBuilder private func whatsNewSection(_ submission: Submission) -> some View {
        let texts = submission.submitted?.whatsNew ?? submission.drafts ?? []
        if !texts.isEmpty {
            CardSection {
                ForEach(texts) { text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text.localeName).appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                        Text(text.text)
                    }
                }
            } header: {
                let title = submission.isSubmitting ? "審査に出している What's New" : "審査に出した What's New"
                Text(submission.submitted == nil ? "What's New の下書き" : title)
            } footer: {
                if let submitted = submission.submitted {
                    let builds = submitted.builds.map { "\($0.platform) (\($0.build))" }.joined(separator: "・")
                    Text("ビルド \(builds) · 配信の方式: \(submitted.releaseType.label)")
                } else {
                    Text("審査に出すときに、言語ごとに直せます。配信した後の GitHub Release にも、審査に出したときの日本語の文を載せます")
                }
            }
        }
    }

    /// 掲載文の案（審査に出した後は、出した直し）
    @ViewBuilder private func listingSection(_ submission: Submission) -> some View {
        if let listing = submission.listing, !listing.current.isEmpty {
            let changes = submission.submitted?.listing ?? listing.drafts
            CardSection {
                if changes.isEmpty {
                    let text = submission.submitted == nil ? "変えません" : submission.isSubmitting ? "変えずに審査に出しています" : "変えずに審査に出しました"
                    Text(text).foregroundStyle(.secondary)
                }
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.localeName).appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                        ForEach(Submission.ListingField.allCases.filter { change.values[$0] != nil }) { field in
                            let value = change.values[field] ?? ""
                            Text("\(field.label)：\(value.isEmpty ? "（空にする）" : value)")
                        }
                    }
                }
            } header: {
                Text(submission.submitted == nil ? "掲載文の案" : submission.isSubmitting ? "審査に出している掲載文" : "審査に出した掲載文")
            } footer: {
                if submission.submitted == nil { Text(listing.reason) }
            }
        }
    }

    /// App Review の情報の案（変えるときだけ。審査に出した後は、出した直し）
    @ViewBuilder private func appReviewSection(_ submission: Submission) -> some View {
        let submitted = submission.submitted
        if let review = submission.appReview, let change = submitted == nil ? review.draft : submitted?.appReview {
            CardSection {
                if let notes = change.notes { Text(notes) }
                if let required = change.demoAccountRequired {
                    Text(required ? "デモアカウント: 要る（パスワードは App Store Connect で入れる）" : "デモアカウント: 要らない")
                }
                if let name = change.demoAccountName { Text("デモアカウントの名前: \(name)") }
            } header: {
                Text(submitted == nil ? "App Review の情報の案" : "審査に出した App Review の情報")
            } footer: {
                if submitted == nil { Text(review.reason) }
            }
        }
    }

    @ViewBuilder private func links(_ submission: Submission) -> some View {
        let repository = store.repository(submission.repositoryID)
        let branchURL = submission.branch.flatMap { branch in repository.flatMap { URL(string: "https://github.com/\($0.fullName)/tree/\(branch)") } }
        let pullURL = submission.nextVersion?.pullRequest.flatMap { repository?.pullRequestURL($0) }
        if branchURL != nil || pullURL != nil {
            CardSection {
                if let branchURL, let branch = submission.branch {
                    Link(destination: branchURL) { Label("\(branch) を開く", systemImage: "arrow.triangle.branch") }
                }
                if let pullURL, let pull = submission.nextVersion?.pullRequest {
                    Link(destination: pullURL) { Label("版を上げる PR #\(pull) を開く", systemImage: "arrow.triangle.pull") }
                }
            }
        }
    }
}
