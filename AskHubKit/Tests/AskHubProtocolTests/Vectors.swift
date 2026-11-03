import Foundation

/// リポジトリ直下の `protocol/vectors/` のテスト用の例を読む（Swift と Kotlin のテストで同じ例を使う）
enum Vectors {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AskHubProtocolTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // AskHubKit
        .deletingLastPathComponent() // リポジトリ直下
        .appendingPathComponent("protocol/vectors")

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}
