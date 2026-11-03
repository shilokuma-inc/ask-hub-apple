import SwiftUI

/// 最終 PR の確認。自動でマージするかとその理由を最初に出し、人が決めていない判断を確かめてからマージする
struct FinalReviewView: View {
    let epicID: Epic.ID

    @Environment(ClientStore.self) private var store
    @State private var shownDecision: DecisionCard?
    @State private var isConfirmingMerge = false
    @State private var isConfirmingAcceptAll = false

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
            .navigationTitle("マージを確かめる")
            .hidesTabBar()
            .safeAreaBar(edge: .bottom) {
                MergeBar(review: review) { isConfirmingMerge = true }
            }
            .sheet(item: $shownDecision) { decision in
                DecisionSheet(epicID: epic.id, decision: decision)
            }
            .confirmationDialog("PR #\(review.pullRequestNumber) をマージしますか？", isPresented: $isConfirmingMerge, titleVisibility: .visible) {
                Button("merge commit でマージする") {
                    Task { await store.send(.merge(epicID: epic.id, headCommit: review.headCommit)) }
                }
            } message: {
                Text("確かめた head（\(review.headCommit)）だけをマージします。この後に push された変更があれば、マージしません")
            }
            .confirmationDialog("残りの判断をまとめて OK にしますか？", isPresented: $isConfirmingAcceptAll, titleVisibility: .visible) {
                Button("\(review.pendingDecisions.count) 件をまとめて OK") {
                    Task { await store.send(.acceptAllDecisions(epicID: epic.id)) }
                }
            }
    }

    private func sections(_ epic: Epic, _ review: FinalReview) -> some View {
        List {
            Section {
                AppHeaderView(
                    repository: store.repository(epic.repositoryID),
                    subtitle: "最終 PR #\(review.pullRequestNumber) · +\(review.additions) −\(review.deletions)",
                    iconSize: 40
                )
            }
            Section("マージの条件") {
                MergePolicyView(review: review)
                ChecksView(checks: review.checks)
                if review.headChangedAfterReview {
                    Label("確かめた後に変更が push されました。変わった判断を確かめ直してください", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            decisionsSection(epic, review)
            if !review.internalDecisions.isEmpty {
                Section {
                    DisclosureGroup("内部の細部の仮決め · \(review.internalDecisions.count)") {
                        ForEach(review.internalDecisions, id: \.self) { Text($0).font(.subheadline) }
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
        Section {
            if !review.pendingDecisions.isEmpty {
                NavigationLink(value: AppRoute.deck(.decisions(epic.id))) {
                    Label("カードで確かめる（\(review.pendingDecisions.count)）", systemImage: "rectangle.stack")
                        .font(.headline)
                }
            }
            ForEach(review.decisions) { decision in
                Button { shownDecision = decision } label: {
                    DecisionRow(decision: decision)
                }
                .buttonStyle(.plain)
            }
            if review.pendingDecisions.count >= 2 {
                Button("残りをまとめて OK…", systemImage: "checkmark.circle") { isConfirmingAcceptAll = true }
            }
        } header: {
            Text("人が決めていない判断 · \(review.reviewedCount) / \(review.decisions.count) を確認")
        } footer: {
            Text("おまかせにした質問と、見た目や挙動に関わる仮決めです。全部を確かめるまでマージできません")
        }
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
                    .font(.headline)
                Text(reasons.map(\.label).joined(separator: "・") + " があるため")
                    .font(.subheadline)
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
            Label(reviewText, systemImage: reviewProblems.isEmpty ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(reviewProblems.isEmpty ? Color.secondary : Theme.danger)
        }
        .font(.subheadline)
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
        case let .waitingForRunner(retry, nextAt): "ランナーの空きを待っています（再試行 \(retry) 回目・次は \(RelativeTime.clock(nextAt))）"
        case let .fixing(category, attempt): "\(category.label)を自動で直しています（\(attempt) / 3）"
        case .failed: "CI が通りませんでした"
        }
    }

    private var ciSymbol: String {
        switch checks.ci {
        case .passed: "checkmark.circle.fill"
        case .running: "clock"
        case .waitingForRunner: "hourglass"
        case .fixing: "wrench.and.screwdriver"
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
                    .font(.caption)
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
        let kind = if case .delegated(let id) = decision.kind { "おまかせ（\(id)）" } else { "見える仮決め" }
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

/// 下のマージのボタン。押せないときは、何が残っているかを書く
private struct MergeBar: View {
    let review: FinalReview
    let onMerge: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if case .merged(let date, let automatic) = review.state {
                Label("\(automatic ? "自動で" : "")マージしました（\(RelativeTime.clock(date))）", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
            } else {
                Button(action: onMerge) {
                    Text(review.state == .merging ? "マージしています…" : "マージする")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!review.canMerge)
                if let reason = blockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var blockedReason: String? {
        guard !review.canMerge, review.state == .reviewable else {
            return nil
        }
        if review.headChangedAfterReview {
            return "確かめた後に変更が入りました"
        }
        let pending = review.decisions.filter { !$0.isConfirmed }.count
        if pending > 0 {
            return "あと \(pending) 件の判断を確かめるとマージできます"
        }
        return "CI とレビューを通ったらマージできます"
    }
}
