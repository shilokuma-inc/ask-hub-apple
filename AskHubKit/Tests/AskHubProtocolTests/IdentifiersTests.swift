@testable import AskHubProtocol
import Foundation
import Testing

private struct IdentifierVectors: Decodable {
    let valid: [String]
    let invalid: [String]
}

private struct IdentifierVectorFile: Decodable {
    let ulid: IdentifierVectors
    let repositoryFullName: IdentifierVectors
    let keyId: IdentifierVectors
    let macName: IdentifierVectors
    let timestamp: IdentifierVectors
}

struct IdentifiersTests {
    private typealias File = IdentifierVectorFile

    @Test func ulidFollowsVectors() throws {
        let vectors = try Vectors.load("identifiers.json", as: File.self).ulid
        try check(vectors, ULID.self)
    }

    @Test func repositoryFullNameFollowsVectors() throws {
        let vectors = try Vectors.load("identifiers.json", as: File.self).repositoryFullName
        try check(vectors, RepositoryFullName.self)
        let name = try #require(RepositoryFullName(rawValue: "shilokuma-inc/ask-hub-apple"))
        #expect(name.owner == "shilokuma-inc")
        #expect(name.name == "ask-hub-apple")
    }

    @Test func keyIDFollowsVectors() throws {
        let vectors = try Vectors.load("identifiers.json", as: File.self).keyId
        try check(vectors, KeyID.self)
    }

    @Test func macNameFollowsVectors() throws {
        let vectors = try Vectors.load("identifiers.json", as: File.self).macName
        try check(vectors, MacName.self)
    }

    @Test func timestampFollowsVectors() throws {
        let vectors = try Vectors.load("identifiers.json", as: File.self).timestamp
        try check(vectors, Timestamp.self)
        for text in vectors.valid {
            #expect(Timestamp(rawValue: text)?.rawValue == text, "\(text)")
        }
    }

    @Test func timestampTruncatesToSeconds() throws {
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_793_700_000.999))
        #expect(timestamp.rawValue == "2026-11-03T10:00:00Z")
        #expect(timestamp == Timestamp(rawValue: "2026-11-03T10:00:00Z"))
        let encoded = try JSONEncoder().encode([timestamp])
        #expect(String(bytes: encoded, encoding: .utf8) == "[\"2026-11-03T10:00:00Z\"]")
    }

    /// 文字列から作るときと、JSON から読むときの両方で、例のとおりに受け付けて弾くか
    private func check<Value: RawRepresentable & Decodable>(
        _ vectors: IdentifierVectors,
        _ type: Value.Type
    ) throws where Value.RawValue == String {
        #expect(!vectors.valid.isEmpty && !vectors.invalid.isEmpty)
        for text in vectors.valid {
            #expect(Value(rawValue: text) != nil, "\(Value.self) は受け付ける: \(text)")
            #expect(throws: Never.self) { try JSONDecoder().decode([Value].self, from: Self.json(text)) }
        }
        for text in vectors.invalid {
            #expect(Value(rawValue: text) == nil, "\(Value.self) は弾く: \(text.debugDescription)")
            #expect(throws: DecodingError.self) { try JSONDecoder().decode([Value].self, from: Self.json(text)) }
        }
    }

    private static func json(_ text: String) throws -> Data {
        try JSONEncoder().encode([text])
    }
}
