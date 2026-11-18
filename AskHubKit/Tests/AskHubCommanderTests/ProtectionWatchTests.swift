@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os
import Testing

/// 掛けた保護のずれの点検（`ProtectionWatch`）
extension ProtectionTests {
    /// 掛けたリポジトリだけを、毎日のトークンで読んで点検し、ずれが変わったときだけ書く
    @Test func watchWritesDriftOnlyWhenItChanges() async throws {
        let applied = RepositoryFile.Protection(appliedAt: Timestamp(Self.now), requiredChecks: ["build / build"], rulesetId: 10)
        let store = try await registered(protection: applied)
        let transport = StubTransport([
            // 1 回目: 必須のチェックが外された
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(
                id: 10, name: "askhub-protect", includes: Self.protectedRefs
            )),
            // 2 回目: 同じずれ（書かない）
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(
                id: 10, name: "askhub-protect", includes: Self.protectedRefs
            )),
            // 3 回目: 直った
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ours),
            // 4 回目: ルールセットごと外された
            .json(200, "[]")
        ])
        let watch = ProtectionWatch(
            context: context(store),
            github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "github_pat_daily" } },
            log: { _ in }
        )
        #expect(try await watch.check(Self.repo))
        let drift = ProtectionDrift(foundAt: Timestamp(Self.now), problems: ["必須のチェックが変わった（今は 無し）"])
        #expect(try await repository(in: store)?.protection.drift == drift)
        #expect(try await !watch.check(Self.repo))
        #expect(try await watch.check(Self.repo))
        #expect(try await repository(in: store)?.protection.drift == nil)
        #expect(try await watch.check(Self.repo))
        #expect(try await repository(in: store)?.protection.drift?.problems == ["ルールセット askhub-protect が無い（外された）"])
        // 点検は読むだけで、毎日のトークンを使う
        #expect(transport.requests.allSatisfy { request in
            request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_daily"
        })
        // 掛けた時刻・必須のチェックは変えない
        #expect(try await repository(in: store)?.protection.appliedAt == Timestamp(Self.now))
    }

    /// 保護を掛けていないリポジトリは点検しない
    @Test func watchSkipsRepositoriesWithoutProtection() async throws {
        let store = try await registered()
        let transport = StubTransport([])
        let watch = ProtectionWatch(
            context: context(store), github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "t" } }, log: { _ in }
        )
        #expect(try await !watch.check(Self.repo))
        #expect(transport.requests.isEmpty)
    }

    /// 点検の途中で掛け直されたら、古い設定と比べたずれを書かない
    @Test func watchDropsResultWhenReappliedMeanwhile() async throws {
        let applied = RepositoryFile.Protection(appliedAt: Timestamp(Self.now), requiredChecks: ["build / build"], rulesetId: 10)
        let store = try await registered(protection: applied)
        var reapplied = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        reapplied.protection = .init(appliedAt: Timestamp(Self.now.addingTimeInterval(60)), requiredChecks: ["lint"], rulesetId: 10)
        let newer = try StateFileCoder.encode(reapplied)
        let transport = HookTransport(base: StubTransport([
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(id: 10, name: "askhub-protect", includes: Self.protectedRefs))
        ])) {
            await store.put(StatePath.repository(Self.repo), data: newer)
        }
        let watch = ProtectionWatch(
            context: context(store), github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "t" } }, log: { _ in }
        )
        #expect(try await !watch.check(Self.repo))
        #expect(try await repository(in: store)?.protection.drift == nil)
        #expect(try await repository(in: store)?.protection.requiredChecks == ["lint"])
    }
}

/// 最初の要求を送る前に、決まった処理を 1 回だけ流す（点検の途中で状態が変わるのを作る）
private final class HookTransport: HTTPTransport {
    private let base: StubTransport
    private let hook: @Sendable () async -> Void
    private let fired = OSAllocatedUnfairLock(initialState: false)

    init(base: StubTransport, hook: @escaping @Sendable () async -> Void) {
        self.base = base
        self.hook = hook
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = fired.withLock { fired in
            defer { fired = true }
            return !fired
        }
        if first { await hook() }
        return try await base.send(request)
    }
}
