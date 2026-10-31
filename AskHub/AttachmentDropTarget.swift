import AskHubKit
import SwiftUI
import UniformTypeIdentifiers

/// 添付のドロップ中に出すオーバーレイの状態（Discussion #784）
enum AttachmentDropOverlayState: Equatable {
    /// ファイルをドラッグしている（落とせば添付になる）
    case files
    /// ファイルでないもの（テキスト・Web の画像やリンク）をドラッグしている。落としても添付にしない（Q2）
    case notFiles

    /// オーバーレイを出すか・どちらの表示にするか。受け口が無効（送信中など）のときと、ドラッグが上に無いときは出さない
    static func state(isTargeted: Bool, isEnabled: Bool, hasFiles: Bool) -> Self? {
        guard isTargeted, isEnabled else {
            return nil
        }
        return hasFiles ? .files : .notFiles
    }
}

/// ドロップ中にフォームの上に重ねる表示。下の Form の操作は塞がない（`allowsHitTesting(false)`）
struct AttachmentDropOverlay: View {
    let state: AttachmentDropOverlayState

    var body: some View {
        ZStack {
            // 下のフォームの文字と重ならないよう、背景はほぼ不透明にする（ウィンドウの背景色の上に色を薄く重ねる）
            RoundedRectangle(cornerRadius: 14)
                .fill(.background.opacity(0.92))
            RoundedRectangle(cornerRadius: 14)
                .fill(tint.opacity(0.08))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: state == .files ? "paperclip.circle.fill" : "nosign")
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title3.bold())
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .padding(12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        state == .files ? .accentColor : .secondary
    }

    var title: String {
        switch state {
        case .files: "ドロップしてファイルを添付"
        case .notFiles: "ファイルではないため添付できません"
        }
    }

    var message: String {
        switch state {
        case .files:
            "テキスト・画像・PDF・zip を添付できます。フォルダは中のファイルを添付します（\(AttachmentLimits.maxCount) ファイルまで）"
        case .notFiles:
            "Finder やデスクトップから、名前の付いたファイルを落としてください"
        }
    }
}

/// ドロップで届いた `NSItemProvider` を、添付にする項目（`DroppedAttachmentItem`）に変える
enum AttachmentDropProviders {
    /// フォームの受け口が受け取る種類。ファイル以外も受け取って、落とした後に「添付できません」と出す（Q2）
    static let acceptedTypes: [UTType] = [.item]

    static func items(from providers: [NSItemProvider]) async -> [DroppedAttachmentItem] {
        var items: [DroppedAttachmentItem] = []
        for provider in providers {
            await items.append(item(from: provider))
        }
        return items
    }

    /// ファイルの URL（`public.file-url`）を持つものだけをファイルとして扱う。Web の URL・画像のデータ・テキストは `.other`
    static func item(from provider: NSItemProvider) async -> DroppedAttachmentItem {
        let type = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            return .other
        }
        // 完了ハンドラはメインスレッドの外で呼ばれるので、`@Sendable` にして MainActor に結び付けない
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
            return .other
        }
        return .fileURL(url)
    }
}

extension AttachmentPickerSection {
    /// ドロップの後に添付欄までスクロールするための id（`ScrollViewReader`）
    static let scrollID = "attachment-picker-section"
}

extension View {
    /// フォーム全体を添付のドロップの受け口にする（macOS だけ。Discussion #784 の Q1）。
    /// iOS / iPadOS では何もしない（画面は「ファイルを添付」ボタンだけのまま）
    func attachmentDropTarget(
        attachments: Binding<[AttachmentFile]>,
        notices: Binding<[String]>,
        isEnabled: Bool
    ) -> some View {
        #if os(macOS)
        modifier(AttachmentDropTargetModifier(attachments: attachments, notices: notices, isEnabled: isEnabled))
        #else
        self
        #endif
    }

    /// 入力欄の上では、フォームの受け口を反応させない（入力欄を優先する。Q1）。macOS だけ
    func attachmentDropExcluded() -> some View {
        #if os(macOS)
        onDrop(of: [.fileURL], delegate: RejectingDropDelegate())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// 入力欄に付けて、ファイルのドラッグを受け付けない（外側のフォームの受け口とオーバーレイを反応させない）
private struct RejectingDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        false
    }

    func performDrop(info: DropInfo) -> Bool {
        false
    }
}

private struct AttachmentDropTargetModifier: ViewModifier {
    @Binding var attachments: [AttachmentFile]
    @Binding var notices: [String]
    let isEnabled: Bool
    @State private var isTargeted = false
    @State private var hasFiles = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let state = AttachmentDropOverlayState.state(isTargeted: isTargeted, isEnabled: isEnabled, hasFiles: hasFiles)
        ScrollViewReader { proxy in
            content
                .onDrop(
                    of: AttachmentDropProviders.acceptedTypes,
                    delegate: Delegate(
                        isEnabled: isEnabled,
                        isTargeted: $isTargeted,
                        hasFiles: $hasFiles,
                        drop: { providers in drop(providers, proxy: proxy) }
                    )
                )
                .overlay {
                    if let state {
                        AttachmentDropOverlay(state: state)
                            // 「視差効果を減らす」のときはフェードだけにする
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25), value: state)
        }
    }

    private func drop(_ providers: [NSItemProvider], proxy: ScrollViewProxy) {
        Task {
            let items = await AttachmentDropProviders.items(from: providers)
            // 読み込む間に送信が始まったら足さない
            guard isEnabled, !items.isEmpty else {
                return
            }
            let outcome = AttachmentDropAdder.add(items, to: attachments)
            attachments = outcome.attachments
            notices = outcome.notices
            // 結果（足したもの・断った理由）が見えるように、添付欄までスクロールする
            withAnimation(reduceMotion ? nil : .default) {
                proxy.scrollTo(AttachmentPickerSection.scrollID, anchor: .center)
            }
        }
    }

    private struct Delegate: DropDelegate {
        let isEnabled: Bool
        @Binding var isTargeted: Bool
        @Binding var hasFiles: Bool
        let drop: ([NSItemProvider]) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            isEnabled
        }

        func dropEntered(info: DropInfo) {
            hasFiles = info.hasItemsConforming(to: [.fileURL])
            isTargeted = true
        }

        /// ファイルでないものも落とせるようにする（落とした後に「添付できません」と出す。Q2）
        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .copy)
        }

        func dropExited(info: DropInfo) {
            isTargeted = false
        }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            guard isEnabled else {
                return false
            }
            drop(info.itemProviders(for: AttachmentDropProviders.acceptedTypes))
            return true
        }
    }
}
#endif
