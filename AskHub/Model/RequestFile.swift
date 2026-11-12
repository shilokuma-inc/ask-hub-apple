import AskHubKit
import AskHubProtocol
import Foundation

/// 依頼に付けて送るファイル。添付欄で選んだファイルの中身に、意図の封筒に書く参照（番号・名前・大きさ・ハッシュ）を添える。
/// ハッシュは作るときに 1 度だけ計る（送り終えるまでの間に、送る形を何度も作り直すので）
struct RequestFile: Hashable {
    let data: Data
    let attachment: RequestAttachment

    /// 添付欄の順に 1 から番号を振る。名前か大きさが司令塔の決まりに合わないファイルがあれば、その説明を返して作らない
    static func make(_ files: [AttachmentFile]) -> Result<[Self], Rejection> {
        guard files.count <= RequestIntent.maximumAttachments else {
            return .failure(Rejection(message: "添付は \(RequestIntent.maximumAttachments) ファイルまでです"))
        }
        var made: [Self] = []
        for (offset, file) in files.enumerated() {
            guard let attachment = RequestAttachment(number: offset + 1, name: file.name, contents: file.data) else {
                return .failure(Rejection(message: "\(file.name) は名前が長すぎるか、使えない文字を含むので送れません。名前を変えて添付し直してください"))
            }
            made.append(Self(data: file.data, attachment: attachment))
        }
        return .success(made)
    }

    struct Rejection: Error, Equatable {
        let message: String
    }

    /// 中身はハッシュで比べる（大きなファイルを丸ごと比べない）
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attachment == rhs.attachment
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(attachment.number)
        hasher.combine(attachment.name)
        hasher.combine(attachment.sha256)
    }
}
