import AskHubKit
import SwiftUI

/// 「リリース準備」の入力欄（Discussion #605）。依頼タブで「リリース準備」を選ぶと出る。
/// リポジトリのリリース準備のワークフロー（`release-prepare.yml`）を `develop` で起動し、その run を出す。
/// `Form` の中に置く `Section` 群で、`Form`・`.formStyle`・`.keyboardDoneButton` は付けないので、埋め込む側の `Form` で 1 回だけ付ける
struct ReleaseRequestFormSections: View {
    /// 依頼先の候補（リポジトリの一覧）は「機能追加・修正」と共有する
    let requestModel: IdeaRequestModel
    let model: ReleaseRequestModel
    let openSettings: () -> Void
    /// キーボードの「完了」は埋め込む側の `Form` に付けるので、フォーカスも埋め込む側が持つ
    let isEditing: FocusState<Bool>.Binding

    @State private var isConfirming = false

    var body: some View {
        @Bindable var model = model
        Group {
            Section {
                repositoryPicker
            } header: {
                Text("リポジトリ")
            } footer: {
                repositoryFooter
            }

            if let context = model.context, context.availability != .notFound {
                Section {
                    TextField("例: 1.1.0", text: $model.versionText)
                        .focused(isEditing)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("release-version")
                    if let version = model.version {
                        LabeledContent("ブランチ", value: version.branchName)
                        LabeledContent("タグ", value: version.tagName)
                    }
                } header: {
                    Text("バージョン")
                } footer: {
                    Text(versionFooter(context))
                }

                if context.latestRun != nil || model.isDispatchPending() {
                    ReleaseRunSection(run: context.latestRun, isDispatchPending: model.isDispatchPending())
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    isEditing.wrappedValue = false
                    isConfirming = true
                } label: {
                    if model.isStarting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("リリース準備を起動しています")
                    } else {
                        Text("リリース準備を始める")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!model.canStart())
                .accessibilityIdentifier("start-release")
            } footer: {
                // ワークフローが無いことはリポジトリの欄の下に出しているので、ここでは重ねない
                if let reason = model.blockingReason(), model.repository != nil, model.context?.availability != .notFound {
                    Text(reason)
                        .foregroundStyle(.red)
                } else {
                    Text("develop から release ブランチを切り、App Store Connect に提出する準備をワークフローが行います。審査への提出は人が行います")
                }
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button("リリース準備を始める") {
                Task { await model.start() }
            }
        } message: {
            Text(confirmationMessage)
        }
        // 依頼先の一覧が取り直されて、選んでいたリポジトリが消えたら選び直してもらう
        .onChange(of: requestModel.repositories) { _, repositories in
            if let repository = model.repository, !repositories.contains(where: { $0.fullName == repository }) {
                Task { await model.select(nil) }
            }
        }
    }

    @ViewBuilder private var repositoryPicker: some View {
        switch requestModel.repositoriesState {
        case .needsToken:
            Button("トークンを設定する", action: openSettings)
            TryDemoButton()

        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity)

        case .loading where requestModel.repositories.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)

        default:
            Picker("リリースするリポジトリ", selection: repositorySelection) {
                Text("選択してください").tag(String?.none)
                ForEach(requestModel.repositorySections(now: Date())) { section in
                    Section(section.title) {
                        ForEach(section.repositories, id: \.self) { repository in
                            Text(InboxSubject.shortRepository(repository)).tag(Optional(repository))
                        }
                    }
                }
            }
            .accessibilityIdentifier("release-repository-picker")
        }
    }

    /// 選ぶと、そのリポジトリのリリースの状態を読み直す
    private var repositorySelection: Binding<String?> {
        Binding {
            model.repository
        } set: { repository in
            Task { await model.select(repository) }
        }
    }

    @ViewBuilder private var repositoryFooter: some View {
        if case let .failed(message) = requestModel.repositoriesState {
            Text(message)
                .foregroundStyle(.red)
        } else {
            switch model.contextState {
            case .idle:
                Text("release-prepare.yml のあるリポジトリで使えます")

            case .loading:
                Text("リリースの状態を読んでいます…")

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)

            case .loaded(let context):
                if context.availability == .notFound {
                    Text("このリポジトリにはリリースのワークフロー（\(ReleaseWorkflow.prepare.file)）がありません")
                        .foregroundStyle(.red)
                } else if let unreleased = context.refs?.unreleasedVersions, !unreleased.isEmpty {
                    Text("準備中のリリース: " + unreleased.map(\.branchName).joined(separator: "、"))
                } else if let latest = context.refs?.latestTaggedVersion {
                    Text("最新のリリース: \(latest.tagName)")
                } else {
                    Text("まだリリースのタグはありません")
                }
            }
        }
    }

    private func versionFooter(_ context: ReleaseRequestModel.Context) -> String {
        if let note = context.marketingVersionNote {
            return note
        }
        if let raw = context.marketingVersion?.raw {
            return "develop の MARKETING_VERSION は \(raw) です。既定値はその次のマイナーで、書き換えられます"
        }
        return "MAJOR.MINOR.PATCH の形で入力してください"
    }

    private var confirmationTitle: String {
        "\(model.version?.description ?? "") のリリース準備を始めますか？"
    }

    private var confirmationMessage: String {
        guard let version = model.version else {
            return ""
        }
        return """
            \(model.repository.map(InboxSubject.shortRepository) ?? "") の develop から \(version.branchName) を作り、\
            App Store Connect に iOS / macOS のバージョン \(version) を作ります。\
            バイナリが App Store Connect に上がり、メタデータとスクリーンショットが反映されます
            """
    }
}

/// リリース準備のワークフローの直近の run
struct ReleaseRunSection: View {
    let run: WorkflowRun?
    /// 起動した直後で、まだ run が一覧に出ていない
    let isDispatchPending: Bool

    var body: some View {
        Section {
            LabeledContent("リリース準備", value: statusText)
            if let run, !isDispatchPending {
                if let title = run.displayTitle {
                    LabeledContent("run", value: title)
                }
                LabeledContent("開始", value: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                Link("run を GitHub で見る", destination: run.url)
            }
        } header: {
            Text("直近の run")
        } footer: {
            if isDispatchPending {
                Text("起動した直後は run の一覧にまだ出ません。少し待つと自動で取り直します")
            }
        }
    }

    private var statusText: String {
        if isDispatchPending {
            return "起動しました"
        }
        guard let run else {
            return "まだありません"
        }
        return UploadRunSection.runText(run)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        NewRequestView(model: .sample(), openSettings: {}, kind: .release)
    }
}
#endif
