import AskHubProtocol
import SwiftUI

/// 最終 PR の確認。自動でマージするかとその理由を最初に出し、人が決めていない判断を確かめてからマージする
struct FinalReviewView: View {
    let epicID: Epic.ID

    @Environment(ClientStore.self) private var store
    @State private var shownDecision: ShownDecision?
    @State private var isConfirmingMerge = false
    /// 確認を開いたときの head（承認をこれに結びつける）
    @State private var mergeHead: String?
    @State private var isConfirmingAcceptAll = false
    /// まとめて OK の確認を開いたときに見ていた head とカード
    @State private var acceptAllTarget: AcceptAllTarget?
    @State private var textRequest: TextRequest?

    /// 開いた判断のカードと、開いたときの head（開いている間に取り直しても、答えは見たときの head に結びつける）
    private struct ShownDecision: Identifiable {
        var decision: DecisionCard
        var headCommit: String?
        var id: DecisionCard.ID { decision.id }
    }

    private struct AcceptAllTarget {
        var headCommit: String?
        var decisionIDs: [DecisionCard.ID]
    }

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
            .safeAreaBar(edge: .bottom) { mergeBar(epic, review) }
            .sheet(item: $shownDecision) { shown in
                DecisionSheet(
                    epicID: epic.id,
                    decision: shown.decision,
                    headCommit: shown.headCommit,
                    canAnswer: review.state == .reviewable
                )
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
                if let head = mergeHead {
                    Button("merge commit でマージする") {
                        Task { await store.send(.merge(epicID: epic.id, headCommit: head)) }
                    }
                }
            } message: {
                Text("確かめた head（\(Self.shortCommit(mergeHead))）だけをマージします。この後に push された変更があれば、マージしません")
            }
            .confirmationDialog("残りの判断をまとめて OK にしますか？", isPresented: $isConfirmingAcceptAll, titleVisibility: .visible) {
                if let target = acceptAllTarget {
                    Button("\(target.decisionIDs.count) 件をまとめて OK") {
                        let intent = HumanIntent.acceptAllDecisions(
                            epicID: epic.id,
                            headCommit: target.headCommit,
                            decisionIDs: target.decisionIDs
                        )
                        Task { await store.send(intent) }
                    }
                }
            }
    }

    private func mergeBar(_ epic: Epic, _ review: FinalReview) -> some View {
        MergeBar(epicID: epic.id, review: review, onInstruct: instruction(epic, review).map { request in { textRequest = request } }) {
            mergeHead = review.headCommit
            isConfirmingMerge = true
        }
        .keepsControlSize()
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
            if !review.screenChanges.isEmpty {
                ScreenChangesSection(changes: review.screenChanges)
            }
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
                Button { shownDecision = ShownDecision(decision: decision, headCommit: review.headCommit) } label: {
                    DecisionRow(epicID: epic.id, decision: decision)
                }
                .buttonStyle(.plain)
            }
            if review.decisions.isEmpty {
                Text("見える仮決めはありません").foregroundStyle(.secondary)
            }
            if canAnswer, review.pendingDecisions.count >= 2 {
                // 残りのどれかへの答えの同期を待つ間は押せなくし、断られた理由などをボタンの下に出す
                // （まとめて OK を送ると、残りがすべて OK の形になってボタンごと消える）
                let pending = review.pendingDecisions.map { IntentTarget.decision(epicID: epic.id, decisionID: $0.id) }
                Button("残りをまとめて OK…", systemImage: "checkmark.circle") {
                    acceptAllTarget = AcceptAllTarget(headCommit: review.headCommit, decisionIDs: review.pendingDecisions.map(\.id))
                    isConfirmingAcceptAll = true
                }
                .disabled(store.isReflecting(pending))
                ReflectionStatusView(pending)
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
        case let .fixing(category, attempt): "\(category.label)を自動で直しています（\(attempt) / \(FixTaskInput.maxAutomaticRounds)）"
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

/// 判断のカードの 1 行。答えを送ったら、反映されるまで印を出す（断られた理由は、開いたシートと帯に出す）
private struct DecisionRow: View {
    let epicID: Epic.ID
    let decision: DecisionCard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                HStack(spacing: 6) {
                    Text(status)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    ReflectionBadge([.decision(epicID: epicID, decisionID: decision.id)])
                }
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

/// 下のマージのボタンと、最終 PR を直してほしいときの指示のボタン。マージを押せないときは、何が残っているかを書く。
/// マージの承認か指示を送ったら、すぐ送った後の形（マージしています…）にし、司令塔が受け付けるまで両方を押せなくする。
/// マージ済みなら、押せない「マージ済」のボタンだけを出す
private struct MergeBar: View {
    let epicID: Epic.ID
    let review: FinalReview
    /// 最終 PR への指示を書く。送れないときは nil（ボタンを出さない）
    let onInstruct: (() -> Void)?
    let onMerge: () -> Void

    @Environment(ClientStore.self) private var store

    var body: some View {
        let target = IntentTarget.finalPullRequest(epicID: epicID)
        let isReflecting = store.isReflecting([target])
        VStack(spacing: 6) {
            if let mergedNote = review.mergedNote {
                // マージ済みは押せない「マージ済」のボタンにし、直しの指示は出さない。自動でかどうかと時刻は下に小さく残す
                Button {} label: {
                    Label("マージ済", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(true)
                Text(mergedNote)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    if let onInstruct {
                        Button("直してほしい…", systemImage: "pencil", action: onInstruct)
                            .buttonStyle(.glass)
                            .disabled(isReflecting)
                    }
                    Button(action: onMerge) {
                        Text(review.state == .merging ? "マージしています…" : "マージする")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!review.canMerge || isReflecting)
                }
                .controlSize(.large)
                if store.reflection(for: [target]) != nil {
                    // 承認か指示を送ったら、司令塔が受け付けるまでは小さな印だけ。しばらく受け取っていない・断られたら理由を出す
                    ReflectionStatusView(target, showsSyncBadge: true)
                        .frame(maxWidth: 520)
                } else if let reason = blockedReason {
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
        if !review.acceptsApproval {
            return "判断の一覧を読めていません。取り直してからマージしてください"
        }
        if review.headCommit == nil {
            return "最終 PR の head が分かりません。取り直してください"
        }
        return "CI とレビューを通ったらマージできます"
    }
}

/// 画面の変化（仮決めに結びつかない、epic 全体で見た目が変わった画面）の Before / After。押すと大きく開く
struct ScreenChangesSection: View {
    let changes: [ScreenChangeCard]

    var body: some View {
        CardSection {
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    Text(change.title)
                        .appFont(.subheadline, weight: .semibold)
                    if change.before != nil || change.after != nil {
                        BeforeAfterView(before: change.before, after: change.after, zoomable: true)
                            .frame(maxHeight: 420)
                    }
                    if let note = change.note {
                        Label(note, systemImage: "info.circle")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("画面の変化")
        } footer: {
            Text("依頼どおりに画面が変わったかを、base との分岐点（Before）と作業ブランチ（After）で比べられます")
        }
    }
}
