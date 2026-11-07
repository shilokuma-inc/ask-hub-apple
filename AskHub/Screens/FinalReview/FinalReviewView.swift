import SwiftUI

/// 最終 PR の確認。自動でマージするかとその理由を最初に出し、人が決めていない判断を確かめてからマージする
struct FinalReviewView: View {
    let epicID: Epic.ID

    @Environment(ClientStore.self) private var store
    @State private var shownDecision: DecisionCard?
    @State private var isConfirmingMerge = false
    @State private var isConfirmingAcceptAll = false
    @State private var textRequest: TextRequest?

    var body: some View {
        if let epic = store.epic(epicID), let review = epic.finalReview {
            content(epic, review)
        } else {
            ContentUnavailableView("最終 PR はまだありません", systemImage: "arrow.triangle.merge")
        }
    }

    private func content(_ epic: Epic, _ review: FinalReview) -> some View {
        sections(epic, review)
            .pastelBackground()
            .compactList()
            .navigationTitle("マージを確かめる")
            .hidesTabBar()
            .safeAreaBar(edge: .bottom) {
                MergeBar(review: review, onInstruct: instruction(epic, review).map { request in { textRequest = request } }) {
                    isConfirmingMerge = true
                }
                .keepsControlSize()
            }
            .sheet(item: $shownDecision) { decision in
                DecisionSheet(epicID: epic.id, decision: decision, canAnswer: review.state == .reviewable)
            }
            .sheet(item: $textRequest) { request in
                TextRequestSheet(request: request, subject: instructionSubject(epic, review)) { text in
                    textRequest = nil
                    Task { await store.send(request.intent(text: text)) }
                } onCancel: {
                    textRequest = nil
                }
            }
            .confirmationDialog("PR #\(review.pullRequestNumber) をマージしますか？", isPresented: $isConfirmingMerge, titleVisibility: .visible) {
                if let head = review.headCommit {
                    Button("merge commit でマージする") {
                        Task { await store.send(.merge(epicID: epic.id, headCommit: head)) }
                    }
                }
            } message: {
                Text("確かめた head（\(Self.shortCommit(review.headCommit))）だけをマージします。この後に push された変更があれば、マージしません")
            }
            .confirmationDialog("残りの判断をまとめて OK にしますか？", isPresented: $isConfirmingAcceptAll, titleVisibility: .visible) {
                Button("\(review.pendingDecisions.count) 件をまとめて OK") {
                    Task { await store.send(.acceptAllDecisions(epicID: epic.id)) }
                }
            }
    }

    private func sections(_ epic: Epic, _ review: FinalReview) -> some View {
        List {
            CardSection {
                AppHeaderView(
                    repository: store.repository(epic.repositoryID),
                    subtitle: (["最終 PR #\(review.pullRequestNumber)"] + [review.lineChanges].compactMap(\.self)).joined(separator: " · "),
                    iconSize: 40
                )
            }
            CardSection("マージの条件") {
                MergePolicyView(review: review)
                ChecksView(checks: review.checks)
                if review.headChangedAfterReview {
                    Label("確かめた後に変更が push されました。変わった判断を確かめ直してください", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            decisionsSection(epic, review)
            if !review.internalDecisions.isEmpty {
                CardSection {
                    DisclosureGroup("内部の細部の仮決め · \(review.internalDecisions.count)") {
                        ForEach(review.internalDecisions, id: \.self) { Text($0).appFont(.subheadline) }
                    }
                } footer: {
                    Text("ユーザーから見える挙動・仕様・見た目に関わらないので、マージの条件には数えません")
                }
            }
            if !review.verifications.isEmpty {
                VerificationSection(epic: epic, items: review.verifications)
            }
        }
    }

    private func decisionsSection(_ epic: Epic, _ review: FinalReview) -> some View {
        let canAnswer = review.state == .reviewable
        return CardSection {
            if canAnswer, !review.pendingDecisions.isEmpty {
                NavigationLink(value: AppRoute.deck(.decisions(epic.id))) {
                    Label("カードで確かめる（\(review.pendingDecisions.count)）", systemImage: "rectangle.stack")
                        .rowFont(.title)
                }
            }
            ForEach(review.decisions) { decision in
                Button { shownDecision = decision } label: {
                    DecisionRow(decision: decision)
                }
                .buttonStyle(.plain)
            }
            if review.decisions.isEmpty {
                Text("見える仮決めはありません").foregroundStyle(.secondary)
            }
            if canAnswer, review.pendingDecisions.count >= 2 {
                Button("残りをまとめて OK…", systemImage: "checkmark.circle") { isConfirmingAcceptAll = true }
            }
        } header: {
            Text("人が決めていない判断 · \(review.reviewedCount) / \(review.decisions.count) を確認")
        } footer: {
            if review.state == .checking {
                Text("最終 PR を確かめ終えたら、判断を確かめられます。全部を確かめるまでマージできません")
            } else {
                Text("ループが実装の中で仮に決めた、見た目や挙動に関わることです。全部を確かめるまでマージできません")
            }
        }
    }

    /// 最終 PR への指示（直してほしいこと）。Claude に直させ、最終 PR のレビューからやり直す（見える仮決めは、スクショを撮り直して再び出す）。
    /// 人が確かめる段階で、見ている head が分かるときだけ出す
    private func instruction(_ epic: Epic, _ review: FinalReview) -> TextRequest? {
        guard review.state == .reviewable, let head = review.headCommit,
              store.supports(.instructFinal(epicID: epic.id, headCommit: head, instruction: "")) else {
            return nil
        }
        return TextRequest(
            title: "最終 PR を直してほしい",
            prompt: "どう直してほしいか",
            purpose: .finalInstruction(epicID: epic.id, headCommit: head)
        )
    }

    /// 文を書くシートの上に出す、何についての指示か
    private func instructionSubject(_ epic: Epic, _ review: FinalReview) -> TextRequestSheet.Subject {
        let appName = store.repository(epic.repositoryID)?.appName
        let context = [appName, "最終 PR #\(review.pullRequestNumber)"].compactMap(\.self).joined(separator: " · ")
        return TextRequestSheet.Subject(context: context, title: epic.title)
    }

    /// コミットの短い形（例: 9f3c2e1）
    private static func shortCommit(_ commit: String?) -> String {
        commit.map { String($0.prefix(7)) } ?? "不明"
    }
}

/// 自動でマージするか、手動ならその理由
private struct MergePolicyView: View {
    let review: FinalReview

    var body: some View {
        switch review.mergePolicy {
        case .automatic:
            Label("CI とレビューを通ったら、自動でマージします", systemImage: "bolt.badge.checkmark")
                .foregroundStyle(Theme.success)

        case .manual(let reasons):
            VStack(alignment: .leading, spacing: 4) {
                Label("手動でマージします", systemImage: "hand.raised.fill")
                    .foregroundStyle(Theme.warning)
                    .rowFont(.title)
                Text(reasons.map(\.label).joined(separator: "・") + " があるため")
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// CI・必須の指摘・セキュリティ・コンフリクト
private struct ChecksView: View {
    let checks: FinalChecks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ciText, systemImage: ciSymbol)
                .foregroundStyle(checks.ci == .passed ? Theme.success : Color.secondary)
            if let findings = checks.findings {
                DisclosureGroup("最後のレビューで直すことになった点") {
                    Text(findings)
                        .appFont(.caption)
                        .textSelection(.enabled)
                }
            } else if checks.ci != .reviewing {
                // レビューの結果を待っている間は、指摘があるかどうか分からないので出さない
                Label(reviewText, systemImage: reviewProblems.isEmpty ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(reviewProblems.isEmpty ? Color.secondary : Theme.danger)
            }
        }
        .appFont(.subheadline)
    }

    private var reviewProblems: [String] {
        var problems: [String] = []
        if checks.requiredFindings > 0 {
            problems.append("必須の指摘 \(checks.requiredFindings) 件")
        }
        if checks.securityFindings > 0 {
            problems.append("セキュリティの指摘 \(checks.securityFindings) 件")
        }
        if checks.hasConflict {
            problems.append("コンフリクト")
        }
        return problems
    }

    private var reviewText: String {
        reviewProblems.isEmpty ? "必須の指摘・セキュリティの指摘・コンフリクトはありません" : reviewProblems.joined(separator: "・") + " があります"
    }

    private var ciText: String {
        switch checks.ci {
        case .passed: "CI は通りました"
        case .running: "CI を流しています"
        case .reviewing: "CI とレビューの結果を待って、確かめています"
        case let .waitingForRunner(retry, nextAt): "ランナーの空きを待っています（再試行 \(retry) 回目・次は \(RelativeTime.clock(nextAt))）"
        case let .fixing(category, attempt): "\(category.label)を自動で直しています（\(attempt) / 3）"
        case .fixingByRequest: "頼まれた直しをしています"
        case .failed: "CI が通りませんでした"
        }
    }

    private var ciSymbol: String {
        switch checks.ci {
        case .passed: "checkmark.circle.fill"
        case .running, .reviewing: "clock"
        case .waitingForRunner: "hourglass"
        case .fixing, .fixingByRequest: "wrench.and.screwdriver"
        case .failed: "xmark.circle.fill"
        }
    }
}

/// 判断のカードの 1 行
private struct DecisionRow: View {
    let decision: DecisionCard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                Text(status)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if decision.after != nil {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private var status: String {
        let kind = "見える仮決め"
        switch decision.response {
        case .pending: return "\(kind) · 未確認"
        case .accepted: return "\(kind) · OK"
        case .fixing(let request): return "直しています: \(request)"
        case .refreshed(let note): return "\(note) · もう一度確かめてください"
        }
    }

    private var symbol: (name: String, color: Color) {
        switch decision.response {
        case .pending: ("circle", Theme.accent)
        case .accepted: ("checkmark.circle.fill", .green)
        case .fixing: ("hammer.circle", .secondary)
        case .refreshed: ("arrow.uturn.backward.circle.fill", .orange)
        }
    }
}

/// 下のマージのボタンと、最終 PR を直してほしいときの指示のボタン。マージを押せないときは、何が残っているかを書く
private struct MergeBar: View {
    let review: FinalReview
    /// 最終 PR への指示を書く。送れないときは nil（ボタンを出さない）
    let onInstruct: (() -> Void)?
    let onMerge: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if case .merged(let date, let automatic) = review.state {
                Label("\(automatic ? "自動で" : "")マージしました（\(RelativeTime.clock(date))）", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
            } else {
                HStack(spacing: 12) {
                    if let onInstruct {
                        Button("直してほしい…", systemImage: "pencil", action: onInstruct)
                            .buttonStyle(.glass)
                    }
                    Button(action: onMerge) {
                        Text(review.state == .merging ? "マージしています…" : "マージする")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!review.canMerge)
                }
                .controlSize(.large)
                if let reason = blockedReason {
                    Text(reason)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var blockedReason: String? {
        guard !review.canMerge else {
            return nil
        }
        switch review.state {
        case .checking:
            return "最終 PR を確かめています。終わったら、判断を確かめてマージできます"

        case .merging, .merged:
            return nil

        case .reviewable:
            break
        }
        if review.headChangedAfterReview {
            return "確かめた後に変更が入りました"
        }
        let pending = review.decisions.filter { !$0.isConfirmed }.count
        if pending > 0 {
            return "あと \(pending) 件の判断を確かめるとマージできます"
        }
        if review.headCommit == nil {
            return "最終 PR の head が分かりません。取り直してください"
        }
        return "CI とレビューを通ったらマージできます"
    }
}
