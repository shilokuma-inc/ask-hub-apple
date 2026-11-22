import AskHubKit
import SwiftUI

/// 依頼の下書き（分け方の案から依頼し直すとき・リリースを直すとき）
struct RequestDraft: Identifiable, Hashable {
    var id: String { "\(release ?? "")/\(summary)" }
    var repositoryID: TargetRepository.ID
    var summary: String
    var body: String
    /// 直すリリースの版（「このリリースを直す」依頼）。依頼先は変えられない
    var release: String?
}

/// 依頼の画面で送るもの
enum RequestKind: Hashable {
    /// 対象のリポジトリへの機能の依頼
    case feature
    /// テンプレートから作る新しいアプリ
    case newApp
}

/// 新しい依頼。依頼先には対象のリポジトリだけを、organization ごとに分けて出す。添付は、意図より先に状態リポジトリに置く。
/// 「新しいアプリ」に切り替えると、テンプレートから新しいアプリのリポジトリを作る（`NewAppSections`）。
///
/// 送っている間は触れなくし、置けたら送った依頼（司令塔が受け取る前の epic）へ移る。同じ下書きのまま、もう一度送れる状態に残さない
struct NewRequestSheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RequestKind
    @State private var newApp = NewAppRequest()
    /// 新しいアプリのアプリ名・Bundle ID を手で直したか。欄は「機能の依頼」に切り替えると作り直されるので、入れた値と同じくここに持つ
    @State private var newAppEdits = NewAppSections.Edits()
    /// 下書き（分け方の案から依頼し直す）から開いたか。下書きなら「新しいアプリ」に切り替えさせない
    private let isDraft: Bool
    @State private var repositoryID: TargetRepository.ID?
    @State private var summary: String
    @State private var requestBody: String
    /// 直すリリースの版。nil ならふだんの依頼（develop に入れ、次のリリースで出す）
    private let release: String?
    @State private var attachments: [AttachmentFile] = []
    /// 選んだのに足さなかったファイル・送れなかったファイルの説明
    @State private var attachmentNotices: [String] = []
    @State private var sending = SheetSendState()
    /// 同じ内容の依頼を少し前に送った時刻（重ねて送るかを確かめる）
    @State private var duplicateSentAt: Date?
    @FocusState private var isEditing: Bool

    init(draft: RequestDraft? = nil, kind: RequestKind = .feature) {
        _kind = State(initialValue: draft == nil ? kind : .feature)
        isDraft = draft != nil
        _repositoryID = State(initialValue: draft?.repositoryID)
        _summary = State(initialValue: draft?.summary ?? "")
        _requestBody = State(initialValue: draft?.body ?? "")
        release = draft?.release
    }

    private var canSend: Bool {
        switch kind {
        case .feature: repositoryID != nil && !summary.trimmingCharacters(in: .whitespaces).isEmpty
        case .newApp: newApp.problem == nil
        }
    }

    /// 送る意図。添付のハッシュを計るので、描くたびではなく送るときに作る。送れない添付があれば、説明を添付欄に出して nil
    private func makeIntent() -> HumanIntent? {
        guard let repositoryID, canSend else {
            return nil
        }
        switch RequestFile.make(attachments) {
        case let .success(files):
            return .request(repositoryID: repositoryID, summary: summary, body: requestBody, attachments: files, release: release)

        case let .failure(rejection):
            attachmentNotices = [rejection.message]
            return nil
        }
    }

    var body: some View {
        let groups = store.snapshot?.repositoryGroups ?? []
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        // 送れなかったときのやり直しも、送るものの種類で分ける（ツールバーのボタンと同じ）
                        SheetSendStatus(state: sending) { kind == .feature ? submit() : create() }
                    }
                }
                if !isDraft {
                    Section {
                        Picker("送るもの", selection: $kind) {
                            Text("機能の依頼").tag(RequestKind.feature)
                            Text("新しいアプリ").tag(RequestKind.newApp)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("request-kind")
                    }
                    .disabled(sending.isSending)
                }
                if kind == .newApp {
                    NewAppSections(request: $newApp, edits: $newAppEdits, owners: store.snapshot?.adminOwners ?? [])
                        .disabled(sending.isSending)
                } else {
                    featureSections(groups: groups)
                }
            }
            .formStyle(.grouped)
            // macOS では、フォームのどこに落としても添付になる（Discussion #784）
            .attachmentDropTarget(attachments: $attachments, notices: $attachmentNotices) { !sending.isSending && kind == .feature }
            .pastelBackground()
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton(kind == .feature ? "送る" : "作る", isSending: sending.isSending) {
                        kind == .feature ? submit() : create()
                    }
                    .disabled(!canSend)
                }
            }
            .confirmationDialog(
                "さきほど同じ依頼を送りました",
                isPresented: Binding { duplicateSentAt != nil } set: { if !$0 { duplicateSentAt = nil } },
                titleVisibility: .visible,
                presenting: duplicateSentAt
            ) { _ in
                Button("もう一度送る") { submit(confirmed: true) }
            } message: { sentAt in
                Text("\(sentAt.formatted(date: .omitted, time: .shortened)) に、同じアプリ・要約・内容・添付の依頼を送っています。もう一度送ると、別の epic がもう 1 つできます")
            }
            .keyboardDoneButton($isEditing)
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    private var title: String {
        switch kind {
        case .feature: release == nil ? "新しい依頼" : "このリリースを直す"
        case .newApp: "新しいアプリ"
        }
    }

    /// 機能の依頼の欄（依頼先・直すリリース・作りたいもの・添付）
    private func featureSections(groups: [RepositoryOwnerGroup]) -> some View {
        Group {
            Section("依頼先") {
                Picker("アプリ", selection: $repositoryID) {
                    Text("選んでください").tag(TargetRepository.ID?.none)
                    // organization ごとの見出しで分ける（同じ名前のリポジトリが別の organization にあっても見分けられる）
                    ForEach(groups) { group in
                        Section(group.owner) {
                            ForEach(group.repositories) { repository in
                                Text(repository.appName).tag(Optional(repository.id))
                            }
                        }
                    }
                }
                // 直すリリースの依頼は、リリースのリポジトリから変えない
                .disabled(release != nil)
                if let repository = store.repository(repositoryID) {
                    AppHeaderView(repository: repository) {
                        OwnerLabel(repository: repository)
                    }
                }
            }
            if let release {
                Section {
                    Label("リリース \(release) を直す", systemImage: "wrench.and.screwdriver")
                        .accessibilityIdentifier("request.release")
                } footer: {
                    Text("直しは release/\(release) に入れ、このリリースのビルドに載せます。配信した後に develop にも取り込みます")
                }
            }
            Section("作りたいもの") {
                // Mac の Form では名前が入力欄の左に並んで欄が狭くなるので、名前は隠して入力欄の中に出す
                TextField("要約（例: 週ごとのまとめ通知）", text: $summary, prompt: Text("要約（例: 週ごとのまとめ通知）"))
                    .labelsHidden()
                    .focused($isEditing)
                    .attachmentDropExcluded()
                TextField("依頼の内容", text: $requestBody, prompt: Text("依頼の内容"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(4...12)
                    .focused($isEditing)
                    .attachmentDropExcluded()
            }
            // 送信中は一覧を変えさせない（送れたら閉じるので、送信中に足したものが黙って消えないように）
            AttachmentPickerSection(attachments: $attachments, notices: $attachmentNotices, isDisabled: sending.isSending)
        }
        .disabled(sending.isSending)
    }

    /// 新しいアプリを作る意図を送る。送れたら閉じて、司令塔が作る前から出ているリポジトリの画面へ移る
    private func create() {
        guard !sending.isSending, newApp.problem == nil else {
            return
        }
        let request = newApp
        Task {
            guard case .sent = await sending.send(.createRepository(request), in: store) else {
                return
            }
            dismiss()
            navigator.open(.repository(request.repositoryID), in: .repositories)
        }
    }

    /// 送る。同じ内容の依頼を少し前に送っていたら、先に確かめる
    private func submit(confirmed: Bool = false) {
        guard !sending.isSending, let intent = makeIntent() else {
            return
        }
        if !confirmed, let sentAt = store.recentlySentRequest(intent) {
            duplicateSentAt = sentAt
            return
        }
        isEditing = false
        Task {
            guard case .sent(let receipt) = await sending.send(intent, in: store) else {
                return
            }
            dismiss()
            // 送った依頼は、司令塔が受け取る前から epic として出ているので、そこへ移る（読めていなければ閉じるだけ）
            if let epicID = receipt.requestedEpicID, store.epic(epicID) != nil {
                navigator.open(.epic(epicID), in: .progress)
            }
        }
    }
}
