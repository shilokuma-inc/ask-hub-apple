import AskHubCommands
import AskHubProtocol
import Foundation

/// `ClaudeRequest` を `claude` のコマンドに組み立てる（`docs/renewal/architecture.md` の「呼び出しの決まり」）
enum ClaudeCommandLine {
    enum Problem: Error, Equatable {
        /// `-` で始まる依頼は、フラグとして読まれるおそれがある
        case promptLooksLikeOption
        /// 引数の全体（依頼・決まりの文・結果の形・フォルダなど）が大きすぎる
        case argumentsTooLarge(bytes: Int)
    }

    static func command(for request: ClaudeRequest, setup: ClaudeSetup) throws(Problem) -> Command {
        guard !request.prompt.hasPrefix("-") else { throw .promptLooksLikeOption }
        let arguments = arguments(for: request)
        // 起動の前に断る（起動の時に E2BIG で失敗すると、原因が依頼の大きさだと分からない）。区切りの NUL も数える
        let bytes = arguments.reduce(setup.executable.path.utf8.count + 1) { $0 + $1.utf8.count + 1 }
        guard bytes <= setup.maximumArgumentBytes else { throw .argumentsTooLarge(bytes: bytes) }
        return Command(
            executable: setup.executable,
            arguments: arguments,
            environment: environment(for: setup),
            workingDirectory: request.workingDirectory,
            timeout: request.timeout
        )
    }

    /// 依頼は `-p` のすぐ後に置く（`--tools` などの複数の値をとるフラグの後ろに置くと、値として読まれる）
    static func arguments(for request: ClaudeRequest) -> [String] {
        var arguments = [
            "-p", request.prompt,
            "--output-format", "json",
            "--model", request.model,
            "--json-schema", CanonicalJSON.string(for: request.outputSchema),
            // 書く・コマンドを流す道具と WebFetch を外し、ユーザー・プロジェクトの設定ファイルと MCP を読まない
            "--restricted",
            "--strict-mcp-config",
            // 許可の一覧にある操作だけ通し、ほかは自動で断る
            "--permission-mode", "dontAsk",
            "--settings", CanonicalJSON.string(for: settings(for: request)),
            "--tools", request.tools.joined(separator: ",")
        ]
        if !request.systemPrompt.isEmpty {
            arguments += ["--append-system-prompt", request.systemPrompt]
        }
        if !request.additionalDirectories.isEmpty {
            arguments += ["--add-dir"] + request.additionalDirectories.map(\.path)
        }
        if let resume = request.resume {
            arguments += ["--resume", resume]
        }
        return arguments
    }

    /// 渡す道具だけを許可する
    static func settings(for request: ClaudeRequest) -> JSONValue {
        .object(["permissions": .object(["allow": .array(request.tools.map(JSONValue.string))])])
    }

    /// 環境変数は作り直し、Claude の認証のほかに資格情報を渡さない。
    /// API キー（`ANTHROPIC_API_KEY`）が環境にあると従量課金で優先されるので、渡さない
    static func environment(for setup: ClaudeSetup) -> [String: String] {
        [
            "HOME": setup.homeDirectory.path,
            "PATH": setup.path,
            "TMPDIR": setup.temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "CLAUDE_CONFIG_DIR": setup.configDirectory.path,
            "CLAUDE_CODE_OAUTH_TOKEN": setup.oauthToken,
            // 版を固定するので、自分で更新しない
            "DISABLE_AUTOUPDATER": "1"
        ]
    }
}
