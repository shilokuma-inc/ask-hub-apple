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
        case "add-repository", "configure-repository", "apply-protection",
             "request", "answer", "clarify", "start", "revise-goal", "decide-split", "abandon",
             "pause", "resume", "handover", "retry", "give-up", "decide", "approve-merge", "instruct-final", "human-task-done":
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
          configure-repository --repo <owner/repo> --file <build.json>   ビルドの設定（repo.json の build と同じ形）を入れる
          apply-protection --repo <owner/repo> [--checks <名前,名前>]   保護の設定（ルールセット askhub-protect）を司令塔に掛けてもらう
                         （必須のチェックは既定で build / build。司令塔の管理用のトークンで掛け、重なる保護を外す）
          request --repo <owner/repo> --title <題> [--body <本文>]
          answer --repo <owner/repo> --epic <id> --question <q1> --version <版> [--choice <選択肢>] [--note <補足>]
          clarify --repo <owner/repo> --epic <id> --question <q1> --version <版> --note <問い>
          start --repo <owner/repo> --epic <id> --version <ゴールの版> --mac <Mac の名前>
          revise-goal --repo <owner/repo> --epic <id> --version <ゴールの版> --instruction <指示>
          decide-split --repo <owner/repo> --epic <id> --version <確認の結果の版> --choice split|proceed
          abandon --repo <owner/repo> --epic <id>   開始する前の epic を取り下げる
          pause --repo <owner/repo> --epic <id>   開始した epic を一時停止する（動いているジョブは最後まで終わらせる）
          resume --repo <owner/repo> --epic <id>   一時停止した epic を再開する
          handover --repo <owner/repo> --epic <id> --mac <Mac の名前>   開始した epic をほかの Mac に引き継ぐ
          decide --repo <owner/repo> --epic <id> --decision <d1> --head <最終 PR の head> --answer ok|alternative|fix [--note <本文>]
          approve-merge --repo <owner/repo> --epic <id> --head <最終 PR の head>   最終 PR のマージを承認する
          instruct-final --repo <owner/repo> --epic <id> --head <最終 PR の head> --instruction <指示>
          human-task-done --repo <owner/repo> --epic <id> --task <h1> --version <ゴールの版> [--file <渡すファイル>]
          retry --repo <owner/repo> --epic <id> --job <id> --attempt <試行の番号>     人の対応待ちのジョブをやり直させる
          give-up --repo <owner/repo> --epic <id> --job <id> --attempt <試行の番号>   人の対応待ちのジョブをやめる
          status [--repo <owner/repo>] [--watch <秒>]   epic・質問・ゴール・人の対応待ちのジョブと、送った意図の処理の結果を出す
            --watch は 60 秒以上の間隔で読み直し、変わったときだけ出す（Ctrl-C で止める）。
            見張るときは --watch を使い、外のループ（while … sleep）で流さない（毎回すべてを GitHub の上限に数えられる）
        """

    static var secrets: KeychainSecretStore { KeychainSecretStore(service: ClientConfiguration.keychainService) }

    /// 設定と鍵と状態リポジトリ
    struct Connection {
        var configuration: ClientConfiguration
        var key: DeviceSigningKey
        var store: GitHubContentsStore
    }

    /// 状態リポジトリの tree と blob（sha で中身が決まる）を持つ場所。1 回きりの `status` も、2 回目からは変わったものだけを GitHub から読む。
    /// 置くのは状態リポジトリの中身だけ（トークンと鍵は置かない）。消えても読み直すだけなので Caches に置く（アプリ・司令塔とは分ける）
    static var objectsDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: ClientConfiguration.keychainService, directoryHint: .isDirectory)
            .appending(path: "state-objects", directoryHint: .isDirectory)
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
            budget: WriteBudget(limits: .client),
            objectsDirectory: objectsDirectory
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
