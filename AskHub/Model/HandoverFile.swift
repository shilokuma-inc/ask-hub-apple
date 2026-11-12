import AskHubProtocol
import Foundation

/// 人がする作業で渡すファイル。選んだときに大きさとハッシュを計り、送るときに意図の封筒に書く
/// （司令塔とワーカーが、置いた中身と照らし合わせる）。名前と大きさは依頼の添付と同じ決まり
struct HandoverFile: Hashable {
    let data: Data
    /// 意図の payload に書く参照（渡すファイルは 1 つなので、番号は 1）
    let attachment: RequestAttachment

    var name: String { attachment.name }
    var size: Int { attachment.size }
    /// 中身の SHA-256（16 進の小文字）
    var sha256: String { attachment.sha256 }

    /// 名前か大きさが決まりに合わなければ nil
    init?(name: String, data: Data) {
        guard let attachment = RequestAttachment(number: 1, name: name, contents: data) else {
            return nil
        }
        self.data = data
        self.attachment = attachment
    }

    /// 中身はハッシュで比べる（大きなファイルを丸ごと比べない）
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.sha256 == rhs.sha256
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(sha256)
    }
}

extension HandoverFile {
    struct ReadFailure: Error, Equatable {
        let message: String
    }

    /// 書類ピッカーで選んだファイルを読む。大きすぎるファイルは、中身を読む前に断る
    static func read(_ url: URL) -> Result<Self, ReadFailure> {
        let name = url.lastPathComponent
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let limit = RequestIntent.maximumAttachmentBytes
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            return .failure(ReadFailure(message: "\(name) は \(limit / 1024 / 1024) MB を超えるので渡せません"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ReadFailure(message: "\(name) を読み込めませんでした"))
        }
        guard !data.isEmpty else {
            return .failure(ReadFailure(message: "\(name) は空なので渡せません"))
        }
        guard let file = Self(name: name, data: data) else {
            return .failure(ReadFailure(message: "\(name) は名前か大きさが決まりに合わないので渡せません"))
        }
        return .success(file)
    }
}
