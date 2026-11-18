@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 保護の設定で、置き換えると守りが弱くなるときは止める・上限は人の意図をまたいで待つ
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

    /// 上限に当たったら、待つ時間が過ぎるまで、同じ持ち主の次の意図も GitHub に送らずに断る
    @Test func sharesRateLimitWaitAcrossIntents() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(429, #"{"message":"rate limited"}"#, headers: ["Retry-After": "120"]),
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, "[]"),
            .json(201, Self.ours),
            .data(Self.classicRules("[]"))
        ])
        let admin = admin(transport)
        let first = try await ApplyProtectionHandler(admin: admin).handle(envelope(), in: context(store))
        guard case let .reject(reason) = first else {
            Issue.record("断っていない: \(first)")
            return
        }
        #expect(reason.hasPrefix("GitHub に届かない・混んでいる"))
        #expect(transport.requests.count == 1)
        // 別の意図（ハンドラーの写し）でも、待つ間は送らない
        let soon = try await ApplyProtectionHandler(admin: admin)
            .handle(envelope(), in: context(store, now: Self.now.addingTimeInterval(60)))
        #expect(soon == .reject("shilokuma-inc の管理用のトークンは GitHub の上限に当たっているので、送らなかった（60 秒ほど待ってから押し直す）"))
        #expect(transport.requests.count == 1)
        let later = try await ApplyProtectionHandler(admin: admin)
            .handle(envelope(), in: context(store, now: Self.now.addingTimeInterval(121)))
        #expect(later == .accept)
        #expect(transport.requests.count == 5)
    }
}
