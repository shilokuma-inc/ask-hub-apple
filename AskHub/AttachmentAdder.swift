import AskHubKit
import Foundation

/// 選んだファイルを添付の一覧に足す（添付欄のボタンとドラッグ&ドロップで共通。Discussion #669・#784）。
/// 足さなかったファイルの理由は注意書きにして返す。注意書きは各モデルの `attachmentNotices` に持たせ、添付欄の外からも書けるようにする
enum AttachmentAdder {
    /// 足した後の一覧と、足さなかったファイルの説明（上限・読めないなど。足したものは含めない）
    struct Outcome: Equatable {
        var attachments: [AttachmentFile]
        var notices: [String]
    }

    /// ファイルの選択そのものが失敗したときの注意書き
    static let importFailedNotice = "ファイルを読み込めませんでした"

    /// `urls` を選んだ順に `attachments` の後ろへ足す。上限の数を超える分は中身を読まずに断る
    static func add(_ urls: [URL], to attachments: [AttachmentFile]) -> Outcome {
        var files: [AttachmentFile] = []
        var unreadable: [String] = []
        // 上限の数を超える分は、中身を読まずに断る（大きなファイルを多く選んだときに、読んでから捨てない）
        let remaining = max(AttachmentLimits.maxCount - attachments.count, 0)
        let overflow = urls.dropFirst(remaining).map { AttachmentLimits.Rejection.tooMany(name: $0.lastPathComponent).message }
        for url in urls.prefix(remaining) {
            switch AttachmentFileReader.read(url) {
            case let .success(file):
                files.append(file)

            case let .failure(failure):
                unreadable.append(failure.message)
            }
        }
        let added = AttachmentLimits.adding(files, to: attachments)
        return Outcome(attachments: added.attachments, notices: unreadable + added.rejections.map(\.message) + overflow)
    }

    /// `fileImporter` の結果を足す。選択が失敗したら一覧は変えずに注意書きだけを返す
    static func add(_ result: Result<[URL], any Error>, to attachments: [AttachmentFile]) -> Outcome {
        switch result {
        case let .success(urls):
            add(urls, to: attachments)

        case .failure:
            Outcome(attachments: attachments, notices: [importFailedNotice])
        }
    }
}
