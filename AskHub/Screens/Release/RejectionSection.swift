import AskHubKit
import SwiftUI

/// 審査で断られた版の対処（`docs/renewal/release.md` の「リジェクト」）。理由を貼る → Claude の直し方の案 → 人が直し方を選ぶ。
/// コードを直すなら「このリリースを直す」依頼の下書きを開き、メタデータ・返信なら、確かめて「審査に出し直す」
struct RejectionSection: View {
    let submission: Submission
    /// 理由を貼るシートを開く（シートは List の外の画面が持つ。Section に付けると行ごとに付いて開かない）
    let onReport: () -> Void
    /// コードを直すときに開く依頼の下書き（貼った画像を付けて開く）
    let onRequestFix: (RequestDraft) -> Void

    @Environment(ClientStore.self) private var store
    @State private var isPreparingFix = false

    var body: some View {
        CardSection {
            if let rejection = submission.rejection {
                report(rejection)
                if let triage = rejection.triage {
                    triageRows(triage, choice: rejection.choice)
                } else if let failure = rejection.failure {
                    Label("直し方の案を書けませんでした: \(failure)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if submission.canReportRejection {
                    Label("Claude が直し方の案を書いています", systemImage: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                if let choice = rejection.choice {
                    Label("選んだ直し方: \(choice.label)", systemImage: choice.systemImage)
                }
            }
            actions
        } header: {
            Text("リジェクト")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if submission.awaitsFixedBuild {
            return "直しの epic をマージして、release ブランチから新しいビルドが上がったら、確かめて審査に出し直せます"
        }
        if submission.rejection?.choice != nil {
            return "直したら、上の「確かめて審査に出す…」で出し直します（App Store Connect で断られたままの提出を出し直します）"
        }
        if submission.awaitsRejectionChoice {
            return "直し方を選んでください。コードを直すなら「このリリースを直す」依頼の下書きを開きます。メタデータ・返信なら、確かめて審査に出し直します"
        }
        return "App Store Connect のアプリで審査の文を見て、文か画面の画像を貼ってください。Claude が直し方の案を書き、最後にあなたが選びます"
    }

    @ViewBuilder private func report(_ rejection: Submission.Rejection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("貼った理由（\(rejection.platforms.joined(separator: "・"))）")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            if !rejection.text.isEmpty {
                Text(rejection.text)
                    .appFont(.footnote)
                    .textSelection(.enabled)
            }
            if !rejection.images.isEmpty {
                Label("画像 \(rejection.images.count)", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func triageRows(_ triage: Submission.RejectionTriage, choice: Submission.Remedy?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude の案: \(triage.remedy.label)", systemImage: triage.remedy.systemImage)
                .appFont(.headline, weight: .semibold)
            Text(triage.summary)
            Text(triage.plan)
                .foregroundStyle(.secondary)
            if !triage.metadataChanges.isEmpty {
                Text("直す案のある欄: \(triage.metadataChanges.joined(separator: "・"))")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("rejection.triage")
        if let reply = triage.reply {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("App Review への返信の下書き")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    CopyReplyButton(value: reply)
                }
                Text(reply)
                    .appFont(.footnote)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let id = submission.repositoryID
        let version = submission.version
        let idle = submission.sending == nil && !store.isReflecting([.submission(repositoryID: id, version: version)])
        if submission.awaitsRejectionChoice, idle,
           store.supports(.resolveRejection(repositoryID: id, version: version, remedy: .reply)) {
            let recommended = submission.rejection?.triage?.remedy
            ForEach(Submission.Remedy.allCases, id: \.self) { remedy in
                Button {
                    choose(remedy)
                } label: {
                    Label(remedy == .code ? "\(remedy.label)…" : remedy.label, systemImage: remedy.systemImage)
                        .badge(remedy == recommended ? Text("案") : nil)
                }
                .disabled(isPreparingFix)
                .accessibilityIdentifier("rejection.choose.\(remedy.rawValue)")
            }
        }
        if submission.canReportRejection, idle,
           store.supports(.reportRejection(repositoryID: id, version: version, text: "理由")) {
            Button(submission.rejection == nil ? "理由を貼る…" : "理由を貼り直す…", systemImage: "doc.on.clipboard") { onReport() }
                .accessibilityIdentifier("rejection.report")
        }
    }

    /// 直し方を選ぶ。コードを直すなら、続けて「このリリースを直す」依頼の下書き（Claude の案と貼った画像）を開く
    private func choose(_ remedy: Submission.Remedy) {
        let intent = HumanIntent.resolveRejection(repositoryID: submission.repositoryID, version: submission.version, remedy: remedy)
        guard remedy == .code else {
            Task { await store.send(intent) }
            return
        }
        isPreparingFix = true
        let submission = submission
        Task {
            defer { isPreparingFix = false }
            guard case .sent = await store.send(intent) else { return }
            onRequestFix(await Self.fixDraft(submission, store: store))
        }
    }

    /// 「このリリースを直す」依頼の下書き。題と本文は Claude の案（無ければ断られた理由の要約）、添付は貼った画像
    static func fixDraft(_ submission: Submission, store: ClientStore) async -> RequestDraft {
        let rejection = submission.rejection
        let triage = rejection?.triage
        let title = triage?.requestTitle ?? "審査で断られた所を直す（\(submission.version)）"
        let reason = [triage?.summary, rejection?.text].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let body = triage?.requestBody ?? "App Store の審査で断られました。断られた理由:\n\n\(reason)"
        var images: [AttachmentFile] = []
        for image in rejection?.images ?? [] {
            guard case let .success(data) = await store.screenshot(at: image.path) else { continue }
            let type = AttachmentFileReader.mimeType(for: URL(fileURLWithPath: image.name))
            images.append(AttachmentFile(name: image.name, type: type, data: data))
        }
        return RequestDraft(
            repositoryID: submission.repositoryID, summary: title, body: body, release: submission.version, attachments: images
        )
    }
}

/// 返信の下書きをコピーする
private struct CopyReplyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
            Pasteboard.copy(value)
            copied = true
        }
        .labelStyle(.iconOnly)
        .sensoryFeedback(.success, trigger: copied)
        .accessibilityIdentifier("rejection.copyReply")
    }
}

/// リジェクトの理由を貼るシート（審査の文と、画面の画像）
struct RejectionReportSheet: View {
    let submission: Submission
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var text = ""
    @State private var images: [AttachmentFile] = []
    @State private var notices: [String] = []
    @FocusState private var isEditing: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("審査の文", text: $text, prompt: Text("App Store Connect の審査の文を貼る"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(6...16)
                        .focused($isEditing)
                        .attachmentDropExcluded()
                        .accessibilityIdentifier("rejection.text")
                } header: {
                    Text("審査の文")
                } footer: {
                    Text("App Store Connect のアプリで、断られた版の App Review の文を開いてコピーしてください。画面のスクショでもかまいません")
                }
                AttachmentPickerSection(attachments: $images, notices: $notices)
            }
            .formStyle(.grouped)
            .attachmentDropTarget(attachments: $images, notices: $notices) { true }
            .pastelBackground()
            .navigationTitle("リジェクトの理由")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送る") { send() }
                        .disabled(!canSend)
                }
            }
            .keyboardDoneButton($isEditing)
        }
        .sheetSize(.page)
    }

    private func send() {
        switch RequestFile.make(images) {
        case let .success(files):
            let intent = HumanIntent.reportRejection(
                repositoryID: submission.repositoryID, version: submission.version, text: text, images: files
            )
            Task { await store.send(intent) }
            onClose()
        case let .failure(rejection):
            notices = [rejection.message]
        }
    }
}
