@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// テンプレートから作る処理のやり直し（途中で止まった後に押し直す）
extension RepositoryCreationTests {
    /// 準備が途中で止まっていたら、作るところはやり直さず、準備だけを流し直す
    @Test func retryResumesStoppedSetup() async throws {
        let store = InMemoryStateStore()
        var file = RepositoryFile(
            repo: Self.repo, platform: .apple, build: try RepositoryTemplate.ios.build(appName: "CreateCheck"), addedAt: Timestamp(Self.now)
        )
        file.created = .init(
            template: .ios,
            appName: "CreateCheck",
            bundleId: "jp.shilokuma.create-check",
            visibility: .public,
            intent: IntentReference(keyId: KeyID(rawValue: String(repeating: "k", count: 43))!, nonce: ULID.generate(at: Self.now)),
            at: Timestamp(Self.now)
        )
        file.setup = RepositorySetup(updatedAt: Timestamp(Self.now), problems: ["GitHub の上限に当たった"])
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
            .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
            .json(200, "[]"),
            .json(200, #"{"object":{"sha":"\#(Self.commit)","type":"commit"}}"#),
            .json(200, #"[{"name":"build.yml","path":".github/workflows/build.yml","sha":"\#(Self.sha("2"))","type":"file"}]"#),
            .json(200, #"{"content":"\#(Data(Self.buildWorkflow.utf8).base64EncodedString())","encoding":"base64"}"#)
        ])
        #expect(try await handler(transport).handle(envelope(), in: context(store)) == .accept)
        // テンプレートから作る・名前を書き換える要求は送らない
        #expect(!transport.requests.contains { $0.url?.path.hasSuffix("/generate") == true || $0.httpMethod == "PATCH" })
        #expect(try await repository(in: store)?.setup?.problems == nil)
        #expect(try await repository(in: store)?.setup?.discussions == .ready)
    }

    /// 前に同じアプリ名に書き換えた（記録を書く前に止まった）なら、書き換えずに記録へ進む。Bundle ID が違えば断る
    @Test func retryAfterRenameBeforeRecord() async throws {
        let renamed = Self.files.map { file -> TreeFile in
            var moved = file
            moved.path = file.path.replacingOccurrences(of: "IOSTemplateApp", with: "CreateCheck")
            return moved
        }
        let entries = renamed.map { #"{"path":"\#($0.path)","mode":"\#($0.mode)","type":"\#($0.type)","sha":"\#($0.sha)"}"# }
        let tree = #"{"sha":"\#(Self.head)","truncated":false,"tree":[\#(entries.joined(separator: ","))]}"#
        let config = "APP_BUNDLE_IDENTIFIER = jp.shilokuma.other\n"
        let existing = #"{"template_repository":{"full_name":"shilokuma-inc/template-app-ios"},"private":false,"default_branch":"develop"}"#
        let transport = StubTransport([
            .json(200, existing),
            .json(200, #"{"object":{"sha":"\#(Self.head)","type":"commit"}}"#),
            .json(200, tree),
            .json(200, Self.blobs([Self.script, config]))
        ])
        let store = InMemoryStateStore()
        guard case let .reject(reason) = try await handler(transport).handle(envelope(), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        #expect(reason.contains("別の Bundle ID"))
        #expect(!transport.requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/git/trees") == true })
        #expect(try await repository(in: store) == nil)
    }
}
