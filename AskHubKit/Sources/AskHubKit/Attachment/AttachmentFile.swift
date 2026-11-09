import Foundation

/// 添付するファイル 1 つ（選んだファイルの中身）
public struct AttachmentFile: Sendable, Equatable, Hashable {
    /// 元のファイル名
    public var name: String
    /// MIME タイプ（例: `image/png`）
    public var type: String
    public var data: Data

    public init(name: String, type: String, data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }
}
