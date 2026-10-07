import AskHubKit
import SwiftUI

/// 担当リポジトリを担当 PC から外す依頼を出すシート（`repo-request` の Issue を、外すリポジトリに作るだけ）。
/// GitHub のリポジトリは消さない
struct RemoveRepositoryView: View {
    /// 外すリポジトリ（`owner/repo`）
    let repository: String
    let model: IdeaRequestModel

    @State private var deletesLocalFiles = true
    @State private var force = false
    @State private var sent: SentRepositoryRequest?
    @Environment(\.dismiss)
    private var dismiss

    private var request: RepositoryRequest {
        .remove(RepositoryRemoval(repository: repository, deletesLocalFiles: deletesLocalFiles, force: force))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("リポジトリ", value: InboxSubject.shortRepository(repository))
                } footer: {
                    Text("担当 PC のオーケストレーターの担当から外します。GitHub のリポジトリは削除しません")
                }

                Section {
                    Toggle("担当 PC のローカルからも削除する", isOn: $deletesLocalFiles)
                    if deletesLocalFiles {
                        Toggle("未 push の変更があっても削除する（強制）", isOn: $force)
                    }
                } footer: {
                    Text(deletesLocalFiles
                        ? "checkout・ループの worktree・DerivedData を削除して容量を空けます。ループの作業ファイルは担当 PC のアーカイブに退避します。"
                            + (force ? "未コミット・未 push・stash があっても削除します" : "未コミット・未 push・stash があれば削除しません")
                        : "ローカルのファイルは残し、担当から外すだけです")
                }

                if let errorMessage = model.repositoryRequestError {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let sent {
                    Section {
                        SentRepositoryRequestRow(sent: sent)
                    } footer: {
                        Text("処理が終わると、依頼 Issue に結果がコメントされます")
                    }
                } else {
                    Section {
                        Button(role: .destructive) {
                            Task { sent = await model.send(request, to: repository) }
                        } label: {
                            if model.isSendingRepositoryRequest {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("担当から外す依頼を送る")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(model.isSendingRepositoryRequest)
                        .accessibilityIdentifier("send-removal")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("担当から外す")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent == nil ? "キャンセル" : "閉じる") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    RemoveRepositoryView(repository: "shilokuma-inc/notti-ios", model: .sample())
}
#endif
