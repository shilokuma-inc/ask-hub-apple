import Foundation

/// アプリのバージョンとビルド番号。Info.plist の辞書から取り出し、読めないときは「不明」にする
struct AppVersionInfo {
    static let unknown = "不明"

    let version: String
    let build: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        version = Self.value(for: "CFBundleShortVersionString", in: infoDictionary)
        build = Self.value(for: "CFBundleVersion", in: infoDictionary)
    }

    private static func value(for key: String, in infoDictionary: [String: Any]?) -> String {
        guard let value = infoDictionary?[key] as? String else {
            return unknown
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? unknown : trimmed
    }
}
