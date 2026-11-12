import SwiftUI

/// リポジトリの画面の「保護」。様子（未設定・掛けた・ずれ）と、外したもの・断られた理由を出し、「保護の設定」のシートを開く
struct ProtectionSection: View {
    let repository: TargetRepository
    let protection: RepositoryProtection

    @Environment(ClientStore.self) private var store
    @State private var showsSheet = false

    var body: some View {
        let reflecting = store.isReflecting([.repository(repository.id)])
        CardSection {
            LabeledContent("様子") {
                Text(stateText).foregroundStyle(isDrifted ? Theme.warning : Color.secondary)
            }
            if case let .drifted(_, problems, _) = protection.state {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
            LabeledContent("必須のチェック", value: protection.requiredChecks.joined(separator: "・"))
            if !protection.replaced.isEmpty {
                LabeledContent("外した保護", value: protection.replaced.joined(separator: "・"))
            }
            if !protection.remaining.isEmpty {
                LabeledContent("外せずに残った保護", value: protection.remaining.joined(separator: "・"))
            }
            if let rejection = protection.rejection {
                Label(rejection, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.warning)
            }
            Button(buttonTitle) { showsSheet = true }
                .disabled(reflecting)
        } header: {
            Text("保護")
        } footer: {
            Text("develop・main・release/** に、PR 必須・必須のチェック・force push と削除の禁止を、例外なしで掛けます。司令塔が管理用のトークンで掛け、ずれは 6 時間ごとに確かめます")
        }
        .sheet(isPresented: $showsSheet) {
            ProtectionSheet(repository: repository, protection: protection)
        }
    }

    private var isDrifted: Bool {
        if case .drifted = protection.state {
            return true
        }
        return false
    }

    private var stateText: String {
        switch protection.state {
        case .notApplied: "まだ掛けていません"
        case .applied(let date): "\(RelativeTime.string(date, now: store.currentDate()))に掛けました"
        case .drifted: "ずれています"
        }
    }

    private var buttonTitle: String {
        switch protection.state {
        case .notApplied: "保護の設定…"
        case .applied: "掛け直す…"
        case .drifted: "掛け直してずれを直す…"
        }
    }
}

/// 保護の設定を送るシート。掛ける中身と、置き換えて外すもの・止まるものを確かめてから送る
struct ProtectionSheet: View {
    let repository: TargetRepository
    let protection: RepositoryProtection

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var checks: String
    @State private var sending = SheetSendState()

    init(repository: TargetRepository, protection: RepositoryProtection) {
        self.repository = repository
        self.protection = protection
        _checks = State(initialValue: protection.requiredChecks.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                Section {
                    LabeledContent("ブランチ", value: RepositoryProtection.branches.joined(separator: "・"))
                    LabeledContent("規則", value: "PR 必須（承認 0）・force push と削除の禁止・例外なし")
                } header: {
                    Text("掛けるもの（ルールセット askhub-protect）")
                }
                Section {
                    TextEditor(text: $checks)
                        .monospaced()
                        .frame(minHeight: 80)
                        .autocorrectionDisabled()
                } header: {
                    Text("必須のチェック")
                } footer: {
                    Text("1 行に 1 つ。GitHub Actions が出したチェックの名前（例: build / build）。既定はビルドの設定の子 PR で待つチェックです。どの PR でも出るものだけにします")
                }
                Section {
                    ForEach(Self.cautions, id: \.text) { caution in
                        Label(caution.text, systemImage: caution.symbol)
                    }
                } header: {
                    Text("気をつけること")
                }
            }
            .disabled(sending.isSending)
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("保護の設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("掛ける", isSending: sending.isSending) { submit() }
                        .disabled(Self.checks(from: checks).isEmpty)
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    /// 掛ける前に確かめてほしいこと
    static let cautions: [(text: String, symbol: String)] = [
        ("develop・main・release/** に重なるクラシックの保護と、このリポジトリのルールセットは、置き換えて外します", "arrow.triangle.swap"),
        (
            "develop・main への直接の push（GitHub Actions の GITHUB_TOKEN のものを含む）は止まります。直接 push するワークフローが残っていないかを先に確かめてください",
            "exclamationmark.triangle"
        ),
        ("private のリポジトリには、今のプランでは掛けられず、司令塔が理由を付けて断ります", "lock")
    ]

    /// 送る。送り始めたらすぐ閉じる。送れなければ理由を出して残る
    private func submit() {
        if sending.submit(.applyProtection(repositoryID: repository.id, requiredChecks: Self.checks(from: checks)), in: store) {
            dismiss()
        }
    }

    /// 入れた必須のチェック（空の行と前後の空白を除き、重ねない）
    static func checks(from text: String) -> [String] {
        var checks: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let check = line.trimmingCharacters(in: .whitespaces)
            if !check.isEmpty, !checks.contains(check) {
                checks.append(check)
            }
        }
        return checks
    }
}

/// リポジトリの画面の「加えるときの準備」。Discussions・ワークフローの直しの PR の様子と、人がすること（Ideas を作る・承認する・やり直す）
struct RepositorySetupSection: View {
    let repository: TargetRepository
    let setup: RepositorySetupStatus

    @Environment(ClientStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var confirmsApproval = false
    @State private var draft: RequestDraft?

    var body: some View {
        let reflecting = store.isReflecting([.repository(repository.id)])
        CardSection {
            LabeledContent("Discussions", value: discussionsText)
            if setup.discussions == .missingCategory, let url = repository.discussionCategoriesURL {
                Button("GitHub でカテゴリ「Ideas」を作る") { openURL(url) }
            }
            LabeledContent("ワークフロー", value: workflowText)
            if let pullRequest = setup.workflowPullRequest {
                ForEach(pullRequest.changes, id: \.self) { change in
                    Text(change).appFont(.caption).foregroundStyle(.secondary)
                }
                if let url = repository.pullRequestURL(pullRequest.number) {
                    Button("PR #\(pullRequest.number) を GitHub で見る") { openURL(url) }
                }
                if pullRequest.state == .open {
                    Button("承認してマージする…") { confirmsApproval = true }
                        .disabled(reflecting)
                }
            }
            if let rejection = setup.approvalRejection {
                Label(rejection, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.warning)
            }
            ForEach(setup.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            Button("準備の依頼を下書きする") { draft = Self.preparationRequest(for: repository) }
            Button("準備をやり直す") {
                Task { await store.send(.addRepository(repositoryID: repository.id)) }
            }
            .disabled(reflecting)
        } header: {
            Text("加えるときの準備")
        } footer: {
            let ran = RelativeTime.string(setup.updatedAt, now: store.currentDate())
            Text("\(ran)に司令塔が管理用のトークンで流しました。CLAUDE.md の節や epic/** の読み替えなど、ほかの残りものは準備の依頼で直します")
        }
        .confirmationDialog("ワークフローの直しをマージしますか？", isPresented: $confirmsApproval, titleVisibility: .visible) {
            if let pullRequest = setup.workflowPullRequest {
                Button("承認してマージする") {
                    let (id, number, head) = (repository.id, pullRequest.number, pullRequest.head)
                    Task { await store.send(.approveSetup(repositoryID: id, pullRequest: number, head: head)) }
                }
            }
        } message: {
            Text("今の head のままマージします。CI が通っていなければ、司令塔が断るので、通ってから承認し直します")
        }
        .sheet(item: $draft) { draft in
            NewRequestSheet(draft: draft)
        }
    }

    /// 加えた後の「準備の依頼」の下書き。リポジトリごとに違う今の仕組みの残りものを、ふだんの epic で Claude に直してもらう
    /// （`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）。人が確かめて直してから送る
    static func preparationRequest(for repository: TargetRepository) -> RequestDraft {
        RequestDraft(
            repositoryID: repository.id,
            summary: "AskHub の準備: 今の仕組みの残りものを外す",
            body: """
                AskHub の新しい仕組みで回すために、今の仕組み（ralph-loop）の残りものを外してください。

                - CLAUDE.md の「ralph-loop による自律開発」などループの節を外し、`## 全員向けの事実` の節にこのリポジトリの事実をまとめる
                - ループの中継のスクリプト（scripts/ralph-*.sh・askhub-manual.sh）と .claude/ralph/ を外す
                - .coderabbit.yaml・.gitignore・README の、今の仕組み（epic/**・ralph）の記述を直す
                - 今の仕組みのラベル・状態用の Issue があれば、外してよいかを質問で確かめる

                ワークフローのファイル（.github/workflows/）は、ワーカーが変えられないので触れないでください。
                CI の `epic/**` を `askhub/**` に読み替える直しが要るときは、要るところを最終 PR の本文に書いてください（人が GitHub で直します）。
                """
        )
    }

    private var discussionsText: String {
        switch setup.discussions {
        case .ready: "使えます"
        case .missingCategory: "カテゴリ「Ideas」がありません"
        case .unknown, nil: "確かめられていません"
        }
    }

    private var workflowText: String {
        guard let pullRequest = setup.workflowPullRequest else {
            return setup.workflowsChecked ? "直すところはありません" : "確かめられていません"
        }
        switch pullRequest.state {
        case .open: return "PR #\(pullRequest.number) の承認を待っています"
        case .merged: return "PR #\(pullRequest.number) をマージしました"
        case .closed: return "PR #\(pullRequest.number) は閉じられました（やり直すと出し直します）"
        }
    }
}
