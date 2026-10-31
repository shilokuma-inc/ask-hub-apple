import AskHubKit
import SwiftUI
import UniformTypeIdentifiers

/// 依頼・回答・「問題あり」で共通の添付欄（Discussion #669）。ファイルを選び、一覧（名前・種類・大きさ）と削除、public の注意書きを出す。
/// 選んだファイルは `AttachmentAdder` で `Data` にして `attachments` に足す（送るまで GitHub に上げない。ファイルの URL は持たない）
struct AttachmentPickerSection: View {
    @Binding var attachments: [AttachmentFile]
    /// 送信中など、一覧を変えさせないとき
    var isDisabled = false
    @State private var isImporting = false
    /// 選んだのに足さなかったファイルの説明（上限・読めないなど）
    @State private var notices: [String] = []

    /// 選べる種類（`claude` が読めるテキスト・画像・PDF。Discussion #669 の Q2。SVG と zip は Discussion #761 の Q5）
    static let allowedContentTypes: [UTType] = [
        .plainText, .markdown, .json, .commaSeparatedText, .yaml,
        .png, .jpeg, .gif, .webP, .svg, .pdf, .zip
    ]

    var body: some View {
        Section {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, file in
                row(file, at: index)
            }
            .onDelete { offsets in
                attachments.remove(atOffsets: offsets)
            }
            .deleteDisabled(isDisabled)

            ForEach(notices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Button("ファイルを添付", systemImage: "paperclip") {
                notices = []
                isImporting = true
            }
            .disabled(isDisabled || attachments.count >= AttachmentLimits.maxCount)
        } header: {
            Text("添付ファイル")
        } footer: {
            Text("""
                public のリポジトリでは、添付したファイルは誰でも見られます（後から消しても履歴に残ります）。\
                テキスト・画像（PNG / JPEG / GIF / WebP / SVG）・PDF は 1 ファイル \(AttachmentSize.displayText(bytes: AttachmentLimits.maxFileSize))、\
                zip は \(AttachmentSize.displayText(bytes: AttachmentLimits.maxZipFileSize)) まで、\(AttachmentLimits.maxCount) ファイルまで添付できます。\
                zip は受け取る側（担当 PC）で展開して使います
                """)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.allowedContentTypes, allowsMultipleSelection: true) { result in
            let outcome = AttachmentAdder.add(result, to: attachments)
            attachments = outcome.attachments
            notices = outcome.notices
        }
        // 送れて一覧が空になったら、前に足さなかったファイルの説明も消す
        .onChange(of: attachments.isEmpty) { _, isEmpty in
            if isEmpty {
                notices = []
            }
        }
    }

    private func row(_ file: AttachmentFile, at index: Int) -> some View {
        let kind = AttachmentKind(mimeType: file.type)
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .lineLimit(2)
                    Text("\(kind.displayName)・\(AttachmentSize.displayText(bytes: file.data.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: Self.systemImage(for: kind))
            }
            Spacer()
            // macOS の Form にはスワイプの削除が無いので、どちらでもボタンで消せるようにする
            Button {
                // 描画の後に一覧が変わっていても、範囲の外を消さない
                if attachments.indices.contains(index) {
                    attachments.remove(at: index)
                }
                notices = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .accessibilityLabel("\(file.name) を削除")
        }
    }

    private static func systemImage(for kind: AttachmentKind) -> String {
        switch kind {
        case .text:
            "doc.text"

        case .image:
            "photo"

        case .pdf:
            "doc.richtext"

        case .zip:
            "doc.zipper"
        }
    }
}

/// `fileImporter` で選んだファイルを読む。ファイルの場所は返さず、名前・種類・中身だけを返す
enum AttachmentFileReader {
    struct Failure: Error {
        let message: String
    }

    static func read(_ url: URL) -> Result<AttachmentFile, Failure> {
        let name = url.lastPathComponent
        // 書類ピッカーで選んだファイルは、読む間だけ security-scoped のアクセスを開く
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // 大きすぎるファイルは、中身を読む前に断る（上限は種類ごと。zip は 50 MB）
        let type = mimeType(for: url)
        let limit = AttachmentLimits.maxFileSize(for: AttachmentKind(mimeType: type))
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            return .failure(Failure(message: AttachmentLimits.Rejection.tooLarge(name: name, limit: limit).message))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(Failure(message: "\(name) を読み込めませんでした"))
        }
        return .success(AttachmentFile(name: name, type: type, data: data))
    }

    /// 拡張子から MIME タイプを決める。分からないテキストは `text/plain`
    static func mimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return "application/octet-stream"
        }
        if let mime = type.preferredMIMEType {
            return mime
        }
        if type.conforms(to: .text) {
            return "text/plain"
        }
        return "application/octet-stream"
    }
}

private extension UTType {
    /// Markdown（`.md`）。システムに登録が無ければ、拡張子から作る
    static let markdown = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}
