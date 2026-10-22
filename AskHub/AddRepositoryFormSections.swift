import AskHubKit
import SwiftUI

/// GitHub にある既存のリポジトリを担当 PC に入れる依頼の入力欄（`repo-request` の `add` の Issue を作るだけ）。依頼タブで「担当に入れる」を選ぶと出る。
/// clone・ラベル・Discussions・ralph-kit の中継の用意と担当への追加は、入れる先の担当 PC のオーケストレーターが行う。
/// `Form` の中に置く `Section` 群で、`Form`・`.formStyle`・`.keyboardDoneButton` は付けない（`NewAppFormSections` と同じ）
struct AddRepositoryFormSections: View {
    let model: IdeaRequestModel

    /// 担当に入れるリポジトリ（`owner/repo`）
    @State private var repository: String?
    /// 入れる先の PC の担当リポジトリ（`owner/repo`）。依頼 Issue はここに作る
    @State private var hub: String?

    private var request: RepositoryRequest {
        .add(RepositoryAddition(repository: repository ?? ""))
    }

    private var canSend: Bool {
        !model.isSendingRepositoryRequest && hub != nil && request.isValid
    }

    var body: some View {
        Group {
            Section {
                Picker("入れるリポジトリ", selection: $repository) {
                    Text("選択してください").tag(String?.none)
                    ForEach(model.repositorySections(now: Date())) { section in
                        Section(section.title) {
                            ForEach(section.repositories, id: \.self) { repository in
                                Text(InboxSubject.shortRepository(repository)).tag(Optional(repository))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("add-repository-picker")
            } header: {
                Text("入れるリポジトリ")
            } footer: {
                if case let .failed(message) = model.repositoriesState {
                    Text(message)
                        .foregroundStyle(.red)
                } else if let repository, model.hasAssignedPC(repository, now: Date()) {
                    // 断られる依頼だが、担当の印が古くなっている途中などもあるので、送信は止めない（Discussion #722 の Q3）
                    Text("このリポジトリには担当 PC がいます。依頼しても断られるので、先にステータスタブで担当から外してください")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("add-repository-assigned-warning")
                } else {
                    Text("GitHub のリポジトリの設定（公開範囲など）は変えません")
                }
            }

            Section {
                Picker("入れる先の PC", selection: $hub) {
                    Text("選択してください").tag(String?.none)
                    ForEach(model.assignedRepositorySections(now: Date())) { section in
                        Section(section.title) {
                            ForEach(section.repositories, id: \.self) { repository in
                                Text(InboxSubject.shortRepository(repository)).tag(Optional(repository))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("add-hub-picker")
            } header: {
                Text("担当 PC")
            } footer: {
                Text("選んだリポジトリと同じ PC の担当に加えます。その PC の決まった場所に clone し（同じリポジトリが既にあればそれを使う）、"
                    + "AskHub のラベル・Discussions・ralph-kit の中継を用意します。中継は develop に直接 push します（できなければ PR を作ります）")
            }

            if let errorMessage = model.repositoryRequestError {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            let added = model.sentRepositoryRequests.filter {
                if case .add = $0.request { true } else { false }
            }
            if !added.isEmpty {
                Section {
                    ForEach(added) { sent in
                        SentRepositoryRequestRow(sent: sent)
                    }
                } header: {
                    Text("送った依頼")
                } footer: {
                    Text("担当に加え終えると、依頼 Issue に結果がコメントされます")
                }
            }

            Section {
                Button {
                    Task {
                        if await model.send(request, to: hub ?? "") != nil {
                            repository = nil
                        }
                    }
                } label: {
                    if model.isSendingRepositoryRequest {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("担当に入れる依頼を送る")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSend)
            }
        }
        .onAppear {
            if hub == nil {
                hub = model.assignedRepositories(now: Date()).first
            }
        }
    }
}
