import AskHubCommands
import Testing

struct RedactionTests {
    static let token = "sk-ant-oat01-" + String(repeating: "x", count: 40)

    @Test func redactsTokens() {
        let github = "ghp_" + String(repeating: "a", count: 36)
        let text = "token sk-ant-api03-abcdefghij \(github) Authorization: Bearer abc.def.ghi-jkl \(Self.token)"
        let redacted = Redaction.redact(text, secrets: [Self.token])
        for secret in ["sk-ant-api03-abcdefghij", "ghp_", "abc.def.ghi-jkl", Self.token] {
            #expect(!redacted.contains(secret), "\(secret)")
        }
    }

    @Test func excerptKeepsTail() {
        let text = String(repeating: "a", count: Redaction.maximumExcerpt) + "末尾"
        #expect(Redaction.excerpt(of: text, secrets: [])?.hasSuffix("末尾") == true)
        #expect(Redaction.excerpt(of: text, secrets: [])?.count == Redaction.maximumExcerpt)
        #expect(Redaction.excerpt(of: "  \n", secrets: []) == nil)
    }
}
