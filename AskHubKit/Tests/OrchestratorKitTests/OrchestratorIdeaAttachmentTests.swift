import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 依頼の添付（Discussion #669）

extension OrchestratorTests {
    private static let created = CommandResult(
        status: 0,
        output: "ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12\n"
    )
    private static let memo = Data("# メモ\n朝だけにしたい\n".utf8)
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    private static let secondID = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

    private static func requestBody(_ markers: [AttachmentMarker]) -> String {
        AttachmentSection.appending(markers, to: "通知を朝だけにしたい", repository: "shilokuma-inc/ask-hub-apple")
    }

    @Test func passesTextInPromptAndImageAsFileThenAppendsToDiscussion() async throws {
        let memo = AttachmentMarker.fixture(name: "memo.md", type: "text/markdown", data: Self.memo)
        let png = AttachmentMarker.fixture(name: "design.png", type: "image/png", data: Self.png, id: Self.secondID)
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, body: Self.requestBody([memo, png]))])
        github.setAttachmentContents([memo.sha: Self.memo, png.sha: Self.png])
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        let prompt = try #require(runtime.inputs.first)
        // テキストはデータとしてプロンプトに入れる。本文の目印はプロンプトに出さない
        #expect(prompt.contains("<request-attachment name=\"memo.md\" type=\"text/markdown\">\n# メモ\n朝だけにしたい\n"))
        #expect(!prompt.contains("ask-hub:attachment"))
        // 画像は一時ディレクトリに置き、claude が読む時点で中身がある
        let directory = attachmentsDirectory.appending(path: "shilokuma-inc/ask-hub-apple/issue-7", directoryHint: .isDirectory)
        let base = directory.path(percentEncoded: false).dropLast()
        #expect(prompt.contains("Read で開いて見てください。場所: \(base)/2-design.png"))
        // 引数の並びを固定する。`Read` の規則は `//` で始まり、パスの末尾に `/` を重ねない
        #expect(runtime.ran.first == [
            "claude", "-p", "--allowedTools", "Bash(gh:*)", "Read(/\(base)/**)", "--add-dir", String(base)
        ])
        #expect(runtime.ran.first?.contains { $0.hasSuffix("//**)") } == false)
        #expect(runtime.directoryContentsDuringRun.first == ["2-design.png": Self.png])
        // コマンドの後に一時ディレクトリを消す
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        // 作った Discussion の本文に、オーケストレーターが添付欄を足す
        #expect(github.appendedAttachments == ["#12: memo.md,design.png"])
        #expect(github.closedIdeas == [7])
    }

    @Test func skipsAttachmentWhoseContentDoesNotMatch() async throws {
        let memo = AttachmentMarker.fixture(name: "memo.md", type: "text/markdown", data: Self.memo)
        let missing = AttachmentMarker.fixture(name: "gone.png", type: "image/png", data: Data([1, 2, 3]))
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, body: Self.requestBody([memo, missing]))])
        // 大きさは同じで中身が違う（SHA が合わない）
        github.setAttachmentContents([memo.sha: Data("# メモ\n夜だけにしたい\n".utf8)])
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        let prompt = try #require(runtime.inputs.first)
        #expect(!prompt.contains("夜だけにしたい"))
        #expect(prompt.contains("memo.md（テキスト・"))
        #expect(prompt.contains("中身が目印（大きさ・SHA）と合いませんでした"))
        #expect(prompt.contains("添付が見つかりませんでした"))
        // 依頼全体は失敗にせず、確かめられなかった添付は Discussion に引き継がない
        #expect(github.closedIdeas == [7])
        #expect(github.appendedAttachments.isEmpty)
    }

    @Test func customCommandWithoutPlaceholderGetsTextOnly() async throws {
        let memo = AttachmentMarker.fixture(name: "memo.md", type: "text/markdown", data: Self.memo)
        let png = AttachmentMarker.fixture(name: "design.png", type: "image/png", data: Self.png, id: Self.secondID)
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, body: Self.requestBody([memo, png]))])
        github.setAttachmentContents([memo.sha: Self.memo, png.sha: Self.png])
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        let command = try IdeaCommandTemplate(arguments: ["claude", "-p", "--allowedTools", "Bash(gh:*)"])
        try await makeOrchestrator(github: github, runtime: runtime, ideaCommand: command).pollOnce()

        let prompt = try #require(runtime.inputs.first)
        #expect(prompt.contains("<request-attachment name=\"memo.md\""))
        #expect(prompt.contains("担当 PC の設定（ideaCommand に {attachmentsPath} が無い）のため渡せませんでした"))
        #expect(logs.recorded.contains { $0.contains("design.png は、ideaCommand に {attachmentsPath} が無いため") })
        // 一時ディレクトリは作らない
        let directory = attachmentsDirectory.appending(path: "shilokuma-inc/ask-hub-apple/issue-7", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        // claude に渡せなかった画像も、中身を確かめられたので Discussion には引き継ぐ（ループの準備で読めるように）
        #expect(github.appendedAttachments == ["#12: memo.md,design.png"])
    }

    @Test func doesNotPassZipToClaudeButCarriesItToDiscussion() async throws {
        let zipData = Data([0x50, 0x4B, 0x03, 0x04]) + Data("readme.txt".utf8)
        let zip = AttachmentMarker.fixture(name: "assets.zip", type: "application/zip", data: zipData)
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, body: Self.requestBody([zip]))])
        github.setAttachmentContents([zip.sha: zipData])
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        let prompt = try #require(runtime.inputs.first)
        // テキストとしてプロンプトに入れず、一時ディレクトリにも置かない（展開は後続のタスク）
        #expect(!prompt.contains("<request-attachment name=\"assets.zip\""))
        #expect(!prompt.contains("readme.txt"))
        #expect(prompt.contains("assets.zip（zip・"))
        #expect(prompt.contains("zip の展開に担当 PC のオーケストレーターが対応していないため渡せませんでした"))
        #expect(runtime.directoryContentsDuringRun.first?.isEmpty ?? true)
        #expect(logs.recorded.contains { $0.contains("assets.zip は zip のため claude に渡せません") })
        // 中身は確かめられたので、Discussion には引き継ぐ（ループの準備で使えるように）
        #expect(github.appendedAttachments == ["#12: assets.zip"])
        #expect(github.closedIdeas == [7])
    }

    @Test func closesRequestEvenIfAppendingToDiscussionFails() async throws {
        let memo = AttachmentMarker.fixture(name: "memo.md", type: "text/markdown", data: Self.memo)
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, body: Self.requestBody([memo]))])
        github.setAttachmentContents([memo.sha: Self.memo])
        github.setAppendAttachmentsFails(true)
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(github.closedIdeas == [7])
        #expect(logs.recorded.contains { $0.contains("Discussion #12 の本文に添付欄を足せませんでした") })
    }

    @Test func doesNotFetchAttachmentsOfUntrustedEditor() async throws {
        // 信用しない人が編集した依頼は、添付も含めて扱わない
        let memo = AttachmentMarker.fixture(name: "memo.md", type: "text/markdown", data: Self.memo)
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7, editor: "someone", body: Self.requestBody([memo]))])
        github.setAttachmentContents([memo.sha: Self.memo])
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(github.fetchedAttachments.isEmpty)
        #expect(runtime.ran.isEmpty)
    }
}
