import AskHubProtocol
import Foundation

/// リポジトリ直下の `protocol/vectors/` のテスト用の例を読む
enum Vectors {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AskHubKeychainTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // AskHubKit
        .deletingLastPathComponent() // リポジトリ直下
        .appendingPathComponent("protocol/vectors")

    struct Ledger: Decodable {
        let accounts: [String]
        let keys: [String: LedgerKey]
        let cases: [LedgerCase]

        func key(_ name: String) -> KeyID {
            KeyID(rawValue: keys[name]?.keyId ?? "")!
        }

        func records(_ name: String) -> [JSONValue] {
            cases.first { $0.name == name }?.records ?? []
        }
    }

    static func ledger() throws -> Ledger {
        try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: directory.appendingPathComponent("key-ledger.json")))
    }
}

struct LedgerKey: Decodable {
    let keyId: String
}

struct LedgerCase: Decodable {
    let name: String
    let records: [JSONValue]
}
