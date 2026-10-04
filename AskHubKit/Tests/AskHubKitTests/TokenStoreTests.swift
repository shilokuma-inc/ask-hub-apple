@testable import AskHubKit
import Testing

struct TokenStoreTests {
    @Test func inMemoryStoreSavesLoadsAndDeletes() throws {
        let store = InMemoryTokenStore()
        #expect(try store.load() == nil)
        try store.save("github_pat_first")
        try store.save("github_pat_second")
        #expect(try store.load() == "github_pat_second")
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
