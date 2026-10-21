import AskHubKit
import Foundation

/// 依頼の添付を取得して claude に渡す形にし、作った Discussion に添付欄を引き継ぐ（Discussion #669 の Q1・Q5）
extension Orchestrator {
    /// 依頼の添付を置く場所の既定（`~/Library/Caches/askhub/attachments`。リポジトリの checkout の外）
    public static var defaultAttachmentsDirectory: URL {
        URL.cachesDirectory.appending(path: "askhub/attachments", directoryHint: .isDirectory)
    }

    /// 依頼ごとの一時ディレクトリ（`<owner>/<repo>/issue-<番号>`）
    func attachmentsDirectory(for issue: IdeaRequestIssue) -> URL {
        attachmentsDirectory
            .appending(path: issue.repository, directoryHint: .isDirectory)
            .appending(path: "issue-\(issue.number)", directoryHint: .isDirectory)
    }

    /// `{attachmentsPath}` に渡すパス。末尾の `/` は付けない（`Read(/{attachmentsPath}/**)` が `//**` にならないように）
    static func attachmentsPath(of directory: URL) -> String {
        var path = directory.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// 一時ディレクトリを空にして作り直す（前の試行が途中で止まって残ったファイルを、別の依頼の内容として読ませない）
    func prepareAttachmentsDirectory(_ directory: URL, for issue: IdeaRequestIssue) {
        try? FileManager.default.removeItem(at: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("\(issue.repository)#\(issue.number) の添付を置くディレクトリを作れませんでした: \(error)")
        }
    }

    /// 依頼の本文の目印が指す添付を、blob SHA で取って確かめる。
    /// テキストはプロンプトに入れ、画像・PDF（と大きなテキスト）は `directory` に置く。`directory` が無ければ（独自の `ideaCommand` に
    /// `{attachmentsPath}` が無い）、画像・PDF は渡せない旨をプロンプトとログに書く。取れない・合わない添付は飛ばす（依頼全体は失敗にしない）。
    /// 依頼 Issue は信用する author のもの（作成者と編集者）だけが渡ってくる（`IdeaRequestTracker.next`）
    func prepareAttachments(for issue: IdeaRequestIssue, directory: URL?) async -> [IdeaAttachment] {
        let name = "\(issue.repository)#\(issue.number)"
        var attachments: [IdeaAttachment] = []
        for (index, marker) in AttachmentMarker.parseAll(issue.body).enumerated() {
            let data: Data
            do {
                data = try await github.attachmentContent(marker, in: issue.repository)
            } catch {
                let reason = Self.fetchFailureReason(error)
                log("\(name) の添付 \(marker.name) を使いません: \(reason)")
                attachments.append(IdeaAttachment(marker: marker, content: .skipped(reason: reason)))
                continue
            }
            if marker.kind == .text, data.count <= IdeaAttachment.maxInlineTextBytes, let text = String(bytes: data, encoding: .utf8) {
                attachments.append(IdeaAttachment(marker: marker, content: .text(text)))
                continue
            }
            guard let directory else {
                log("\(name) の添付 \(marker.name) は、ideaCommand に {attachmentsPath} が無いため claude に渡せません")
                attachments.append(IdeaAttachment(
                    marker: marker,
                    content: .skipped(reason: "担当 PC の設定（ideaCommand に {attachmentsPath} が無い）のため渡せませんでした"),
                    isVerified: true
                ))
                continue
            }
            // 同じ名前の添付が重ならないよう、番号を前に付ける
            let file = directory.appending(path: "\(index + 1)-\(AttachmentFileName.sanitized(marker.name))", directoryHint: .notDirectory)
            do {
                try data.write(to: file)
                attachments.append(IdeaAttachment(marker: marker, content: .file(path: Self.attachmentsPath(of: file))))
            } catch {
                log("\(name) の添付 \(marker.name) を置けませんでした: \(error)")
                attachments.append(IdeaAttachment(marker: marker, content: .skipped(reason: "担当 PC に置けませんでした"), isVerified: true))
            }
        }
        return attachments
    }

    /// 作った Discussion の本文の末尾に、確かめられた添付の添付欄を足す（claude に SHA を写させない）。
    /// 失敗してもログに残すだけで、依頼のクローズは今どおり進める
    func appendAttachments(_ attachments: [IdeaAttachment], toDiscussion url: URL, of issue: IdeaRequestIssue) async {
        let markers = attachments.filter(\.isVerified).map(\.marker)
        guard !markers.isEmpty, let number = Int(url.lastPathComponent) else {
            return
        }
        do {
            try await github.appendAttachments(markers, toDiscussion: number, in: issue.repository)
            log("\(issue.repository)#\(issue.number) の添付 \(markers.count) 件を Discussion #\(number) の本文に足しました")
        } catch {
            log("Discussion #\(number) の本文に添付欄を足せませんでした（依頼のクローズは続けます）: \(error)")
        }
    }

    private static func fetchFailureReason(_ error: any Error) -> String {
        switch error {
        case AttachmentFetchError.notFound:
            "添付が見つかりませんでした"

        case AttachmentFetchError.sizeMismatch, AttachmentFetchError.shaMismatch:
            "中身が目印（大きさ・SHA）と合いませんでした"

        case AttachmentFetchError.malformedMarker, AttachmentFetchError.invalidContent:
            "添付を読めませんでした"

        default:
            "添付を取得できませんでした"
        }
    }
}
