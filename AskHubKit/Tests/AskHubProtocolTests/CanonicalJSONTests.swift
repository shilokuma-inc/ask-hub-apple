@testable import AskHubProtocol
import Foundation
import Testing

private struct CanonicalJSONVector: Decodable {
    let name: String
    let input: String
    let canonical: String?
    let error: String?
}

private struct CanonicalJSONVectorFile: Decodable {
    let valid: [CanonicalJSONVector]
    let invalid: [CanonicalJSONVector]
}

struct CanonicalJSONTests {
    private typealias File = CanonicalJSONVectorFile

    @Test func canonicalizesVectors() throws {
        let file = try Vectors.load("canonical-json.json", as: File.self)
        #expect(!file.valid.isEmpty)
        for vector in file.valid {
            let value = try JSONValue(parsing: vector.input)
            #expect(CanonicalJSON.string(for: value) == vector.canonical, "\(vector.name)")
        }
    }

    @Test func rejectsInvalidVectors() throws {
        let file = try Vectors.load("canonical-json.json", as: File.self)
        #expect(!file.invalid.isEmpty)
        for vector in file.invalid {
            #expect("\(vector.name): \(parseError(vector.input))" == "\(vector.name): \(vector.error ?? "")")
        }
    }

    @Test func canonicalBytesAreUTF8() {
        let value = JSONValue.object(["日本語": .string("😀")])
        #expect(CanonicalJSON.data(for: value) == Data("{\"日本語\":\"😀\"}".utf8))
    }

    private func parseError(_ input: String) -> String {
        do {
            _ = try JSONValue(parsing: input)
            return "parsed"
        } catch let error as JSONValue.ParseError {
            return "\(error)"
        } catch {
            return "unexpected \(error)"
        }
    }
}
