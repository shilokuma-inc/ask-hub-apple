@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 保護の設定で、置き換えると守りが弱くなるときは止める
extension ProtectionTests {
    /// 同じ名前のルールセットが守る範囲の外（stable）にも掛かっていれば、置き換えずに（何も変えずに）断る
    @Test func refusesToOverwriteSameNameRulesetBeyondPolicy() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, #"[{"id":20,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(id: 20, name: "askhub-protect", includes: ["refs/heads/develop", "refs/heads/stable"]))
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない: \(decision)")
            return
        }
        #expect(reason.hasPrefix("shilokuma-inc/askhub-sandbox に今あるルールセット askhub-protect は、守るブランチ（develop・main・release/ の下）のほかにも掛かる"))
        #expect(transport.requests.map(\.httpMethod) == ["GET", "GET", "GET"])
        #expect(try await repository(in: store)?.protection == RepositoryFile.Protection())
    }

    /// 掛けた結果に例外（bypass）が残っていれば、ほかの保護を外さず、掛けたことを書いた上で断る
    @Test func keepsOtherProtectionWhenAppliedRulesetIsNotPolicy() async throws {
        let store = try await registered()
        let bypassed = Self.ours.replacingOccurrences(
            of: #""bypass_actors":[]"#, with: #""bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]"#
        )
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, "[]"),
            .json(201, bypassed)
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        #expect(decision == .reject(
            "ルールセットは掛けたが、重なる保護を外しきれなかった: 掛けたルールセットが決まりの形にならなかったので、何も外さなかった（例外（bypass）が足された）。もう一度押すと残りを外す"
        ))
        // クラシックの保護の一覧も読まない
        #expect(transport.requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        #expect(try await repository(in: store)?.protection.rulesetId == 10)
    }
}
