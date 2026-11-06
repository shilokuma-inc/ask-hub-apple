@testable import AskHubProtocol
import Testing

private struct MarkerRenderVector: Decodable {
    let name: String
    let value: JSONValue
    let line: String
}

private struct MarkerParseVector: Decodable {
    let name: String
    let text: String
    let parsed: Bool
    let body: String?
    let value: JSONValue?
}

private struct MarkerVectorFile: Decodable {
    let render: [MarkerRenderVector]
    let parse: [MarkerParseVector]
}

struct ProtocolMarkerTests {
    private typealias File = MarkerVectorFile

    @Test func rendersVectors() throws {
        let file = try Vectors.load("marker.json", as: File.self)
        for vector in file.render {
            #expect(ProtocolMarker.line(for: vector.value) == vector.line, "\(vector.name)")
            let json = ProtocolMarker.line(for: vector.value)
                .dropFirst(ProtocolMarker.prefix.count)
                .dropLast(ProtocolMarker.suffix.count)
            #expect(!json.contains("-->"), "\(vector.name)")
        }
    }

    @Test func parsesVectors() throws {
        let file = try Vectors.load("marker.json", as: File.self)
        #expect(!file.parse.isEmpty)
        for vector in file.parse {
            let parsed = ProtocolMarker.parse(vector.text)
            #expect((parsed != nil) == vector.parsed, "\(vector.name)")
            if vector.parsed {
                #expect(parsed?.body == vector.body, "\(vector.name)")
                #expect(parsed?.value == vector.value, "\(vector.name)")
            }
        }
    }

    @Test func textPutsMarkerAfterBody() throws {
        let value = JSONValue.object(["type": .string("status")])
        let text = ProtocolMarker.text(body: "本文\r\n\r\n", marker: value)
        #expect(text == "本文\n\n<!-- askhub v1 {\"type\":\"status\"} -->")
        #expect(ProtocolMarker.parse(text) == ProtocolMarker.Parsed(body: "本文", value: value))
    }
}
