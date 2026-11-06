import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 非常口のコマンド。Mac の端末から、人の意図に署名して状態リポジトリに置く（クライアントが壊れても操作できるように）。
/// 鍵とトークンは、この Mac の Keychain（サービス `jp.shilokuma.AskHub.cli`）にだけ置く
@main
enum AskHubMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "" : arguments.removeFirst()
        do {
            try await run(command, arguments)
        } catch let error as CommandArguments.Failure {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        } catch {
            fail("\(error)", status: EX_SOFTWARE)
        }
    }

    static func run(_ command: String, _ arguments: [String]) async throws {
        switch command {
        case "setup": try setup(CommandArguments(arguments))
        case "key": try await key(arguments)
        case "add-repository", "request", "answer", "clarify", "start", "revise-goal", "decide-split":
            try await send(command, CommandArguments(arguments))
        case "status": try await status(CommandArguments(arguments))
        default: fail(usage, status: command.isEmpty || command == "help" ? EX_OK : EX_USAGE)
        }
    }

    static let usage = """
        使い方: askhub <コマンド>
          setup --state-repo <owner/repo> [--state-branch <ブランチ>]   設定・GitHub のトークン・署名の鍵を用意する
          key show | key register-first --account <GitHub のアカウント> --label <名前>
          key add --public-key <base64url> --account <アカウント> --label <名前> | key revoke <鍵の id>
          add-repository --repo <owner/repo>
          request --repo <owner/repo> --title <題> [--body <本文>]
          answer --repo <owner/repo> --epic <id> --question <q1> --version <版> [--choice <選択肢>] [--note <補足>]
          clarify --repo <owner/repo> --epic <id> --question <q1> --version <版> --note <問い>
          start --repo <owner/repo> --epic <id> --version <ゴールの版> --mac <Mac の名前>
          revise-goal --repo <owner/repo> --epic <id> --version <ゴールの版> --instruction <指示>
          decide-split --repo <owner/repo> --epic <id> --version <確認の結果の版> --choice split|proceed
          status [--repo <owner/repo>]   epic・質問・ゴールと、送った意図の処理の結果を出す
        """

    static var secrets: KeychainSecretStore { KeychainSecretStore(service: ClientConfiguration.keychainService) }

    /// 設定と鍵と状態リポジトリ
    struct Connection {
        var configuration: ClientConfiguration
        var key: DeviceSigningKey
        var store: GitHubContentsStore
    }

    static func connection() throws -> Connection {
        let configuration: ClientConfiguration
        do {
            configuration = try ClientConfiguration.load()
        } catch {
            fail("設定を読めない。setup を流す（\(error.localizedDescription)）", status: EX_CONFIG)
        }
        let secrets = secrets
        // 署名の鍵は setup でだけ作る（ほかのコマンドで黙って新しい鍵を作らない）
        guard try secrets.read(.signingKey) != nil else { fail("署名の鍵が無い。setup を流す", status: EX_CONFIG) }
        let key = try DeviceSigningKey.loadOrCreate(in: secrets)
        let store = GitHubContentsStore(
            repository: configuration.stateRepository,
            branch: configuration.stateBranch,
            budget: WriteBudget(limits: .client)
        ) {
            guard let data = try secrets.read(.githubToken), let token = String(bytes: data, encoding: .utf8), !token.isEmpty else {
                throw StateStoreError.tokenUnavailable
            }
            return token
        }
        return Connection(configuration: configuration, key: key, store: store)
    }

    static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("askhub: \(message)\n".utf8))
        exit(status)
    }

    /// 端末から、表示せずに 1 行読む（端末でなければ止める）
    static func readSecret(_ prompt: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        defer { buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let line = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            fail("端末から入れてください（トークンは引数や標準入力では受け取りません）", status: EX_USAGE)
        }
        return String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
