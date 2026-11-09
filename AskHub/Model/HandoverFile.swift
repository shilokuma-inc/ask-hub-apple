import AskHubProtocol
import CryptoKit
import Foundation

/// 人がする作業で渡すファイル。選んだときに大きさとハッシュを計り、送るときに意図の封筒に書く
/// （司令塔とワーカーが、置いた中身と照らし合わせる）。名前と大きさは依頼の添付と同じ決まり
struct HandoverFile: Hashable {
    let name: String
    let data: Data
    /// 中身の SHA-256（16 進の小文字）
    let sha256: String

    var size: Int { data.count }

    /// 意図の payload に書く参照（渡すファイルは 1 つなので、番号は 1）
    var attachment: RequestAttachment {
        RequestAttachment(number: 1, name: name, size: size, sha256: sha256)
    }

    /// 名前か大きさが決まりに合わなければ nil
    init?(name: String, data: Data) {
        guard Self.isName(name), (1...RequestIntent.maximumAttachmentBytes).contains(data.count) else {
            return nil
        }
        self.name = name
        self.data = data
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 中身はハッシュで比べる（大きなファイルを丸ごと比べない）
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.sha256 == rhs.sha256
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(sha256)
    }

    /// 司令塔が `humanTaskDone` を読むときと同じ決まり（1〜200 文字・パスの区切りと制御文字を含まない）
    private static func isName(_ name: String) -> Bool {
        (1...200).contains(name.unicodeScalars.count) && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
