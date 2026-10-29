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
    /// テキストはプロンプトに入れ、画像・PDF（と大きなテキスト）は `directory` に置く。zip は `directory` の下に展開する（`prepareZip`）。
    /// `directory` が無ければ（独自の `ideaCommand` に
    /// `{attachmentsPath}` が無い）、画像・PDF・zip は渡せない旨をプロンプトとログに書く。取れない・合わない添付は飛ばす（依頼全体は失敗にしない）。
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
            // zip はテキストとしてプロンプトに入れず、一時ディレクトリの下に展開して中のファイルを Read で読ませる（Discussion #761）
            if marker.kind == .zip {
                attachments.append(await prepareZip(marker, data: data, index: index, directory: directory, issue: issue))
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

    /// zip を `directory` に置き、その隣の `<番号>-<名前>.d/` に展開する（`docs/protocol.md` の「zip の展開」）。
    /// 展開できない zip（上限超え・壊れた zip・zip でない）は、その添付だけを理由つきで飛ばす。中身は blob SHA で確かめられたので Discussion には引き継ぐ
    private func prepareZip(
        _ marker: AttachmentMarker,
        data: Data,
        index: Int,
        directory: URL?,
        issue: IdeaRequestIssue
    ) async -> IdeaAttachment {
        let name = "\(issue.repository)#\(issue.number)"
        guard let directory else {
            log("\(name) の添付 \(marker.name) は、ideaCommand に {attachmentsPath} が無いため claude に渡せません")
            return IdeaAttachment(
                marker: marker,
                content: .skipped(reason: "担当 PC の設定（ideaCommand に {attachmentsPath} が無い）のため渡せませんでした"),
                isVerified: true
            )
        }
        // zip は展開先の外に置く（展開先は展開の前に消される）。番号を前に付けるので、ほかの添付のファイル・展開先と重ならない
        let fileName = "\(index + 1)-\(Self.zipFileName(marker.name))"
        let archive = directory.appending(path: fileName, directoryHint: .notDirectory)
        let destination = directory.appending(path: "\(fileName).d", directoryHint: .isDirectory)
        // 展開先は消してから作り直されるので、添付のキャッシュの下（`/` や想定外の場所でない）であることを確かめる
        guard Self.isStrictlyInside(destination, attachmentsDirectory), Self.isStrictlyInside(archive, attachmentsDirectory) else {
            log("\(name) の添付 \(marker.name) の展開先が添付の置き場所の外になるため展開しません: \(destination.path(percentEncoded: false))")
            return IdeaAttachment(marker: marker, content: .skipped(reason: "担当 PC に展開できませんでした"), isVerified: true)
        }
        do {
            // 展開は zip を mmap で読むので、同じパスを切り詰めて書き直さず、別のファイルに書いてから置き換える
            try data.write(to: archive, options: .atomic)
        } catch {
            log("\(name) の添付 \(marker.name) を置けませんでした: \(error)")
            return IdeaAttachment(marker: marker, content: .skipped(reason: "担当 PC に置けませんでした"), isVerified: true)
        }
        // 展開は同期の I/O（最大 100 MB）なので、actor を止めないよう actor の外で行う
        let extractor = zipExtractor
        let result = await Task.detached {
            Result { () throws(AttachmentZipError) -> AttachmentZipContents in
                try extractor.extract(zipAt: archive, to: destination)
            }
        }.value
        switch result {
        case let .success(contents):
            log(
                "\(name) の添付 \(marker.name) を展開しました（読めるもの \(contents.readableFiles.count) 件・素材 \(contents.materials.count) 件・"
                    + "展開しなかった項目 \(contents.skippedEntries.count) 件）: \(contents.directory)"
            )
            return IdeaAttachment(marker: marker, content: .archive(contents))

        case let .failure(error):
            log("\(name) の添付 \(marker.name) を展開できませんでした（依頼は続けます）: \(error.message)")
            return IdeaAttachment(marker: marker, content: .skipped(reason: error.message), isVerified: true)
        }
    }

    /// `url` が `root` の下（`root` そのものでない）か。`..` を解いた形の要素で比べる。`root` が `/` なら、どこも下とみなさない
    static func isStrictlyInside(_ url: URL, _ root: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return rootComponents.count > 1 && components.count > rootComponents.count && components.starts(with: rootComponents)
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

    /// 担当 PC に置く zip の名前（と展開先の `.d` の名前）。プロンプトの「場所」は `"`・`<`・制御文字・見えない文字を無害化して出すので、
    /// それらを含む名前では場所が実在するパスと食い違い、中のファイルを Read で開けない。前もって `_` にしておく
    static func zipFileName(_ name: String) -> String {
        let scalars = AttachmentFileName.sanitized(name).unicodeScalars.map { scalar -> Unicode.Scalar in
            let isInvisible = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            return scalar == "\"" || scalar == "<" || isInvisible ? "_" : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
