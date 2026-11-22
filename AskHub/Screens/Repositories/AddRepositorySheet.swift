import SwiftUI

/// 対象に加える。司令塔が読んだ候補（まだ対象になっていないリポジトリ）を持ち主ごとに並べて選ぶ。候補に無ければ owner/name を入れる
struct AddRepositorySheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: String?
    @State private var fullName = ""
    @State private var sending = SheetSendState()

    var body: some View {
        let allCandidates = store.snapshot?.candidateRepositories ?? []
        let removed = store.snapshot?.removedRepositories ?? []
        let problems = store.snapshot?.candidateProblems ?? []
        let groups = Dictionary(grouping: allCandidates.filter { $0.matches(query) }) { $0.owner.lowercased() }
            .sorted { $0.key < $1.key }
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                ForEach(groups, id: \.key) { _, candidates in
                    Section(candidates[0].owner) {
                        Picker(candidates[0].owner, selection: candidateSelection) {
                            ForEach(candidates) { candidate in
                                CandidateRow(candidate: candidate).tag(Optional(candidate.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if !allCandidates.isEmpty, groups.isEmpty {
                    Section {
                        Text("「\(query)」に合う候補はありません")
                            .foregroundStyle(.secondary)
                    }
                }
                if !removed.isEmpty {
                    Section {
                        Picker("外したリポジトリ", selection: candidateSelection) {
                            ForEach(removed) { repository in
                                Text("\(repository.appName)（\(repository.fullName)）").tag(Optional(repository.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("外したリポジトリを戻す")
                    } footer: {
                        Text("ビルドの設定などは、外す前のまま戻ります")
                    }
                }
                manualSection(hasCandidates: !allCandidates.isEmpty, problems: problems)
            }
            .disabled(sending.isSending)
            .searchable(text: $query, prompt: "名前・説明で探す")
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("対象に加える")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("加える", isSending: sending.isSending) { submit() }
                        .disabled(target == nil)
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    /// 送るリポジトリ。owner/name を入れていればそれ（形が違えば nil）、無ければ選んだ候補・外したリポジトリ
    private var target: String? {
        fullName.isEmpty ? selectedID : Self.repositoryID(fullName)
    }

    /// 候補・外したリポジトリを選んだら、入れた owner/name は消す（どちらを送るかを 1 つにする）
    private var candidateSelection: Binding<String?> {
        Binding {
            fullName.isEmpty ? selectedID : nil
        } set: { id in
            fullName = ""
            selectedID = id
        }
    }

    /// 候補に無いリポジトリの owner/name。候補を読めなかった持ち主があれば、その理由も出す
    private func manualSection(hasCandidates: Bool, problems: [RepositoryCandidateProblem]) -> some View {
        Section {
            TextField("owner/name", text: $fullName, prompt: Text("owner/name"))
                .labelsHidden()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("add-repository-full-name")
        } header: {
            Text(hasCandidates ? "一覧に無いリポジトリ" : "リポジトリ")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                }
                Text(Self.manualFooter(hasCandidates: hasCandidates))
            }
        }
    }

    static func manualFooter(hasCandidates: Bool) -> String {
        let candidates = "候補は、司令塔が毎日のトークンで 1 時間ごとに読み直します"
            + "（private のものは、毎日のトークンの Repository access に足したものだけ出ます）"
        let example = "例: shilokuma-inc/askhub-sandbox。"
        return hasCandidates ? example + candidates : example + "司令塔が受け取ると、対象の一覧に出ます。" + candidates
    }

    /// 送る。送り始めたら（同じものを送ってあったときも）すぐ閉じ、一覧は加えた形になる。送れなければ理由を出して残る
    private func submit() {
        guard let target else {
            return
        }
        if sending.submit(.addRepository(repositoryID: target), in: store) {
            dismiss()
        }
    }

    /// 入れた owner/name。形が違えば nil（送る前に止める）
    static func repositoryID(_ text: String) -> TargetRepository.ID? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return parts.joined(separator: "/")
    }
}

/// 候補の 1 行（名前・private の印・説明）
private struct CandidateRow: View {
    let candidate: RepositoryCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(candidate.name)
                if candidate.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("private")
                }
            }
            if let description = candidate.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
