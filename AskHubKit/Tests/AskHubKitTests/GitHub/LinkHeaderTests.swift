@testable import AskHubKit
import Foundation
import Testing

struct LinkHeaderTests {
    @Test func extractsNextURL() {
        let header = #"<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="next", <https://api.github.com/x?page=9>; rel="last""#
        #expect(LinkHeader.nextURL(from: header)?.absoluteString == "https://api.github.com/x?page=3")
    }

    @Test func returnsNilWithoutNext() {
        #expect(LinkHeader.nextURL(from: nil) == nil)
        #expect(LinkHeader.nextURL(from: #"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(LinkHeader.nextURL(from: "壊れたヘッダー") == nil)
    }
}
