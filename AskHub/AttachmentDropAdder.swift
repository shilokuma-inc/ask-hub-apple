import AskHubKit
import Foundation
import UniformTypeIdentifiers

/// ドラッグ&ドロップで届いた 1 つの項目（Discussion #784）。受け口（`NSItemProvider` を読む側）が作る
enum DroppedAttachmentItem: Equatable, Sendable {
    /// 名前の付いたファイル・フォルダの URL（`file://`）
    case fileURL(URL)
    /// ファイルでないもの（Web の URL・名前の無い画像のデータ・選んだテキストなど）。添付にしない（Q2）
    case other
}

/// ドロップされた項目を添付の一覧に足す（Discussion #784 の Q2・Q3）。UI に依存しないので、iOS / macOS の共通のコードに置く。
/// 種類の確認はここで行う（ドロップには `fileImporter` の `allowedContentTypes` の絞り込みが効かないため）
enum AttachmentDropAdder {
    /// フォルダの中をたどる項目の数の上限。巨大なフォルダ（ホームなど）を落としたときに固まらないようにする
    static let maxFolderEntries = 1_000
    /// 除いたファイルの注意書きに並べる名前の数
    static let excludedNamesShown = 3

    static let otherItemsNotice = "ファイルではない項目（テキスト・Web の画像やリンクなど）は添付できません。名前の付いたファイルを落としてください"

    /// `items` を落とした順に 1 つずつ足す。ファイルはボタンで選んだときと同じ規則（入る数まで足し、超えた分は 1 つずつ断る）。
    /// フォルダは中の受け付ける種類のファイルを展開し、すでにある添付と合わせて上限の数を超えるなら 1 つも足さない
    static func add(_ items: [DroppedAttachmentItem], to attachments: [AttachmentFile]) -> AttachmentAdder.Outcome {
        var outcome = AttachmentAdder.Outcome(attachments: attachments, notices: [])
        var hasOther = false
        for item in items {
            switch item {
            case let .fileURL(url) where url.isFileURL:
                let added = add(url, to: outcome.attachments)
                outcome.attachments = added.attachments
                outcome.notices += added.notices

            case .fileURL, .other:
                hasOther = true
            }
        }
        if hasOther {
            outcome.notices.append(otherItemsNotice)
        }
        return outcome
    }

    /// ボタン（`fileImporter`）で選べる種類か。拡張子から作った `UTType` が、選べる種類のどれかに conform するかで判定する
    static func isAllowedType(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return AttachmentPickerSection.allowedContentTypes.contains { type.conforms(to: $0) }
    }

    static func unsupportedTypeNotice(name: String) -> String {
        "\(name) は添付できない種類のファイルです（テキスト・画像・PDF・zip を添付できます）"
    }

    private static func add(_ url: URL, to attachments: [AttachmentFile]) -> AttachmentAdder.Outcome {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        // シンボリックリンクはたどらない（リンクの先の、落とした覚えのないファイルを読ませない）
        if values?.isSymbolicLink == true {
            return AttachmentAdder.Outcome(attachments: attachments, notices: [unsupportedTypeNotice(name: url.lastPathComponent)])
        }
        if values?.isDirectory == true, values?.isPackage != true {
            return addFolder(url, to: attachments)
        }
        guard isAllowedType(url) else {
            return AttachmentAdder.Outcome(attachments: attachments, notices: [unsupportedTypeNotice(name: url.lastPathComponent)])
        }
        return AttachmentAdder.add([url], to: attachments)
    }

    /// フォルダの中身。受け付ける種類のファイルと、除いたもの（種類の対象外・シンボリックリンク・パッケージ）の名前
    struct FolderContents: Equatable {
        var files: [URL] = []
        var excluded: [String] = []
        /// たどる項目の数の上限（`maxFolderEntries`）を超えた
        var isTooLarge = false
    }

    /// フォルダの中をたどる。隠しファイル（`.DS_Store` など）は黙って除き、パッケージ（`.app` など）の中には入らない。
    /// 呼ぶ側がフォルダの security-scoped のアクセスを開いておく
    static func contents(of folder: URL, maxEntries: Int = maxFolderEntries) -> FolderContents {
        var contents = FolderContents()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return contents
        }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxEntries {
                contents.isTooLarge = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isPackage == true {
                // リンクの先・パッケージの中は読まない（enumerator はリンクのフォルダの中へは入らない）
                contents.excluded.append(url.lastPathComponent)
            } else if values?.isDirectory == true {
                continue
            } else if values?.isRegularFile == true, isAllowedType(url) {
                contents.files.append(url)
            } else {
                contents.excluded.append(url.lastPathComponent)
            }
        }
        // フォルダの中の順は決まっていないので、名前の順にそろえる（同じフォルダを落とせば同じ順に並ぶ）
        contents.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return contents
    }

    private static func addFolder(_ folder: URL, to attachments: [AttachmentFile]) -> AttachmentAdder.Outcome {
        let name = folder.lastPathComponent
        // 中のファイルは、フォルダのアクセスを開いている間に読む
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        let contents = contents(of: folder)
        if contents.isTooLarge {
            return AttachmentAdder.Outcome(
                attachments: attachments,
                notices: ["フォルダ \(name) は中の項目が多すぎるため、1 つも足していません（\(maxFolderEntries) 項目まで）"]
            )
        }
        var notices: [String] = []
        if !contents.excluded.isEmpty {
            notices.append(excludedNotice(folder: name, excluded: contents.excluded))
        }
        if contents.files.isEmpty {
            notices.append("フォルダ \(name) の中に、添付できる種類のファイルがありません")
            return AttachmentAdder.Outcome(attachments: attachments, notices: notices)
        }
        // 全部か 0 か（Q3）。すでにある添付と合わせて上限の数を超えるなら、1 つも足さない
        if attachments.count + contents.files.count > AttachmentLimits.maxCount {
            notices.append("""
                フォルダ \(name) の \(contents.files.count) ファイルを足すと \(AttachmentLimits.maxCount) ファイルを超えるため、\
                1 つも足していません（今の添付は \(attachments.count) ファイル）
                """)
            return AttachmentAdder.Outcome(attachments: attachments, notices: notices)
        }
        let added = AttachmentAdder.add(contents.files, to: attachments)
        return AttachmentAdder.Outcome(attachments: added.attachments, notices: notices + added.notices)
    }

    private static func excludedNotice(folder: String, excluded: [String]) -> String {
        let names = excluded.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = names.prefix(excludedNamesShown).joined(separator: "・")
        let rest = names.count > excludedNamesShown ? " など" : ""
        return "フォルダ \(folder) の中の \(excluded.count) ファイルは、添付できない種類のため除きました（\(shown)\(rest)）"
    }
}
