@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// テンプレートから新しいアプリのリポジトリを作る（`createRepository`）
struct RepositoryCreationTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-create-check")!
    static let now = ProtectionTests.now
    static let head = String(repeating: "1", count: 40)
    static let commit = String(repeating: "c", count: 40)
    static let script = """
        #!/bin/bash
        set -euo pipefail

        OLD_NAME="IOSTemplateApp"
        OLD_REPO="shilokuma-inc/template-app-ios"
        """
    static let config = "// IOSTemplateApp\nDEVELOPMENT_TEAM = XU74X3434S\nAPP_BUNDLE_IDENTIFIER = jp.shilokuma.IOSTemplateApp\n"
    static let view = "import SwiftUI\n\nstruct ContentView: View {}\n// IOSTemplateApp\n"
    /// テンプレートの Build（ドキュメントだけの変更でも流す形。準備で直すところが無い）
    static let buildWorkflow = "name: Build\non:\n  push:\n    branches:\n      - '**'\njobs:\n  build:\n    uses: ./.github/workflows/_build.yml\n"
    static let readme = "# IOSTemplateApp\n\n[![Build](https://github.com/shilokuma-inc/template-app-ios/actions)]\n"

    /// テンプレートのファイル（sha は中身ごとに決めた 40 桁）
    static let files = [
        TreeFile(path: "scripts/rename.sh", mode: "100755", type: "blob", sha: sha("a")),
        TreeFile(path: "Configs/Project.xcconfig", mode: "100644", type: "blob", sha: sha("b")),
        TreeFile(path: "IOSTemplateApp/ContentView.swift", mode: "100644", type: "blob", sha: sha("d")),
        TreeFile(path: "IOSTemplateApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png", mode: "100644", type: "blob", sha: sha("e")),
        TreeFile(path: "README.md", mode: "100644", type: "blob", sha: sha("f"))
    ]

    static func sha(_ character: Character) -> String {
        String(repeating: character, count: 40)
    }

    func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    func envelope(visibility: String = "public", appName: String = "CreateCheck") -> IntentEnvelope {
        IntentEnvelope(
            kind: CreateRepositoryIntent.kind,
            repo: Self.repo,
            payload: [
                "template": .string("ios"),
                "visibility": .string(visibility),
                "appName": .string(appName),
                "bundleId": .string("jp.shilokuma.create-check")
            ],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    func handler(_ transport: StubTransport, token: String? = ProtectionTests.adminToken) -> CreateRepositoryHandler {
        let admin = AdminGitHub(tokens: AdminTokens { _ in token }, transport: transport)
        return CreateRepositoryHandler(admin: admin, wait: .zero, attempts: 3, sleeper: ImmediateSleeper())
    }

    static var tree: String {
        let entries = files.map { #"{"path":"\#($0.path)","mode":"\#($0.mode)","type":"\#($0.type)","sha":"\#($0.sha)"}"# }
        let folder = #"{"path":"IOSTemplateApp","mode":"040000","type":"tree","sha":"\#(sha("9"))"}"#
        return #"{"sha":"\#(head)","truncated":false,"tree":[\#(([folder] + entries).joined(separator: ","))]}"#
    }

    /// 読む blob の中身（sha の順に b0, b1, …）。画像は読まない
    static var blobs: String {
        func text(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return #"{"text":"\#(escaped)","isBinary":false,"isTruncated":false}"#
        }
        let nodes = [script, config, view, readme].enumerated().map { #""b\#($0)":\#(text($1))"# }
        return #"{"data":{"repository":{\#(nodes.joined(separator: ","))}}}"#
    }

    // MARK: - 名前の書き換え

    @Test func renamePlanMovesPathsAndReplacesTexts() throws {
        let old = try #require(TemplateRename.oldNames(in: Self.script))
        #expect(old.name == "IOSTemplateApp")
        #expect(old.repo == "shilokuma-inc/template-app-ios")
        let texts: [String: String?] = [
            Self.sha("a"): Self.script, Self.sha("b"): Self.config, Self.sha("d"): Self.view, Self.sha("f"): Self.readme
        ]
        let names = TemplateRename.Names(appName: "CreateCheck", repo: Self.repo.rawValue, bundleId: "jp.shilokuma.create-check")
        let plan = try #require(TemplateRename.plan(files: Self.files, texts: texts, old: old, new: names))
        #expect(plan.map(\.path) == [
            "scripts/rename.sh",
            "Configs/Project.xcconfig",
            "CreateCheck/ContentView.swift",
            "CreateCheck/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "README.md"
        ])
        // rename.sh 自身と画像は中身を変えず、同じ blob を使う
        #expect(plan[0].content == nil)
        #expect(plan[0].mode == "100755")
        #expect(plan[3].content == nil)
        #expect(plan[3].sha == Self.sha("e"))
        #expect(plan[1].content == "// CreateCheck\nDEVELOPMENT_TEAM = XU74X3434S\nAPP_BUNDLE_IDENTIFIER = jp.shilokuma.create-check\n")
        #expect(plan[2].content == "import SwiftUI\n\nstruct ContentView: View {}\n// CreateCheck\n")
        #expect(plan[4].content?.contains("github.com/shilokuma-inc/askhub-create-check/actions") == true)
        // 書き換え済み（元の名前のパスが無い）なら、何もしない
        #expect(TemplateRename.plan(files: plan, texts: texts, old: old, new: names) == nil)
        #expect(!TemplateRename.needsText(Self.files[3]))
    }

    // MARK: - 作る

    /// テンプレートから作り、ブランチが出るまで待ち、名前を書き換えたコミットを develop に入れ、対象に加えて準備を流す
    @Test func createsFromTemplateRenamesAndAddsRepository() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, "{}"),
            .json(404, #"{"message":"Not Found"}"#),
            .json(200, #"{"object":{"sha":"\#(Self.head)","type":"commit"}}"#),
            .json(200, Self.tree),
            .json(200, Self.blobs),
            .json(201, #"{"sha":"\#(Self.sha("7"))"}"#),
            .json(201, #"{"sha":"\#(Self.commit)"}"#),
            .json(200, "{}"),
            // 加えるときの準備（Discussions を有効にし、Ideas がある。ワークフローは直すところが無い）
            .json(200, #"{"default_branch":"develop","private":false,"has_discussions":false}"#),
            .json(200, "{}"),
            .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
            .json(200, "[]"),
            .json(200, #"{"object":{"sha":"\#(Self.commit)","type":"commit"}}"#),
            .json(200, #"[{"name":"build.yml","path":".github/workflows/build.yml","sha":"\#(Self.sha("2"))","type":"file"}]"#),
            .json(200, #"{"content":"\#(Data(Self.buildWorkflow.utf8).base64EncodedString())","encoding":"base64"}"#)
        ])
        #expect(try await handler(transport).handle(envelope(), in: context(store)) == .accept)
        let requests = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(Array(requests.prefix(9)) == [
            "GET /repos/shilokuma-inc/askhub-create-check",
            "POST /repos/shilokuma-inc/template-app-ios/generate",
            "GET /repos/shilokuma-inc/askhub-create-check/git/ref/heads/develop",
            "GET /repos/shilokuma-inc/askhub-create-check/git/ref/heads/develop",
            "GET /repos/shilokuma-inc/askhub-create-check/git/trees/\(Self.head)",
            "POST /graphql",
            "POST /repos/shilokuma-inc/askhub-create-check/git/trees",
            "POST /repos/shilokuma-inc/askhub-create-check/git/commits",
            "PATCH /repos/shilokuma-inc/askhub-create-check/git/refs/heads/develop"
        ])
        #expect(Set(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }) == ["Bearer \(ProtectionTests.adminToken)"])
        try expectRenameCommit(transport.bodies)
        try await expectCreatedRepository(in: store)
    }

    /// 作る要求は既定のブランチだけを写し、tree は base を使わず全部のファイルを並べ、ブランチは force にせず進める
    private func expectRenameCommit(_ bodies: [JSONValue]) throws {
        #expect(bodies[0] == .object([
            "owner": .string("shilokuma-inc"), "name": .string("askhub-create-check"),
            "private": .bool(false), "include_all_branches": .bool(false)
        ]))
        // 変えたものは中身、変えないものは sha
        guard case let .array(entries)? = bodies.first(where: { $0["tree"] != nil })?["tree"] else {
            Issue.record("tree の本文が無い")
            return
        }
        #expect(entries.count == Self.files.count)
        #expect(entries.contains(.object([
            "path": .string("CreateCheck/Assets.xcassets/AppIcon.appiconset/AppIcon.png"), "mode": .string("100644"),
            "type": .string("blob"), "sha": .string(Self.sha("e"))
        ])))
        #expect(bodies.contains(.object(["sha": .string(Self.commit), "force": .bool(false)])))
    }

    /// 作った記録・テンプレートから決まるビルドの設定・準備が書かれ、保護は掛けていない
    private func expectCreatedRepository(in store: InMemoryStateStore) async throws {
        let file = try #require(try await repository(in: store))
        let created = try #require(file.created)
        #expect(created.template == .ios)
        #expect(created.appName == "CreateCheck")
        #expect(created.renameCommit == Self.commit)
        #expect(file.build == (try RepositoryTemplate.ios.build(appName: "CreateCheck")))
        #expect(file.setup?.discussions == .ready)
        #expect(file.setup?.workflows?.state == .notNeeded)
        #expect(file.protection.appliedAt == nil)
    }

    /// 同じ名前でテンプレートから作ったものでないリポジトリ・公開範囲が違うものは、作り直さずに断る
    @Test func refusesExistingRepositoryNotFromTheTemplate() async throws {
        let store = InMemoryStateStore()
        let other = StubTransport([.json(200, #"{"template_repository":null,"private":false,"default_branch":"main"}"#)])
        guard case let .reject(reason) = try await handler(other).handle(envelope(), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        #expect(reason.contains("既にある"))
        let visibility = StubTransport([
            .json(200, #"{"template_repository":{"full_name":"shilokuma-inc/template-app-ios"},"private":false,"#
                + #""default_branch":"develop"}"#)
        ])
        guard case let .reject(why) = try await handler(visibility).handle(envelope(visibility: "private"), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        #expect(why.contains("public で作ってある"))
        #expect(other.requests.count == 1)
        #expect(try await repository(in: store) == nil)
    }

    /// 前に作り終えたリポジトリへのやり直しは、GitHub に送らずに受け付ける。対象に加えただけのリポジトリは断る
    @Test func retryAfterCompletionAndPlainTargets() async throws {
        let store = InMemoryStateStore()
        var file = RepositoryFile(
            repo: Self.repo, platform: .apple, build: try RepositoryTemplate.ios.build(appName: "CreateCheck"), addedAt: Timestamp(Self.now)
        )
        file.created = .init(
            template: .ios,
            appName: "CreateCheck",
            bundleId: "jp.shilokuma.create-check",
            visibility: .public,
            renameCommit: Self.commit,
            intent: IntentReference(keyId: KeyID(rawValue: String(repeating: "k", count: 43))!, nonce: ULID.generate(at: Self.now)),
            at: Timestamp(Self.now)
        )
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        let transport = StubTransport([])
        #expect(try await handler(transport).handle(envelope(), in: context(store)) == .accept)
        #expect(transport.requests.isEmpty)
        // 別の中身で作り直そうとしたら断る
        guard case .reject = try await handler(transport).handle(envelope(appName: "Other"), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        // 対象に加えただけのリポジトリは作らない
        let plain = InMemoryStateStore()
        let added = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        await plain.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(added))
        guard case .reject = try await handler(transport).handle(envelope(), in: context(plain)) else {
            Issue.record("断っていない")
            return
        }
        #expect(transport.requests.isEmpty)
    }

    /// 管理用のトークンが無い持ち主には作らない（GitHub に送らず、状態リポジトリにも書かない）
    @Test func refusesWithoutAdminToken() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([])
        guard case let .reject(reason) = try await handler(transport, token: nil).handle(envelope(), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        #expect(reason == AdminTokenProblem.missing(owner: "shilokuma-inc").description)
        #expect(transport.requests.isEmpty)
        #expect(try await repository(in: store) == nil)
    }

    /// ブランチが出ないまま待ちきったら、作ったことは残したまま断る（押し直すと続きから）
    @Test func refusesWhenGenerationIsStillRunning() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, "{}"),
            .json(404, #"{"message":"Not Found"}"#),
            .json(404, #"{"message":"Not Found"}"#),
            .json(404, #"{"message":"Not Found"}"#)
        ])
        guard case let .reject(reason) = try await handler(transport).handle(envelope(), in: context(store)) else {
            Issue.record("断っていない")
            return
        }
        #expect(reason.contains("作っている途中"))
        #expect(try await repository(in: store) == nil)
    }
}

/// 待たずに戻る
private struct ImmediateSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {}
}
