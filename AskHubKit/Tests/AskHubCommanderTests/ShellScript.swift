import AskHubCommands
import Foundation

/// テストの準備で `/bin/sh -c` を流し、標準出力と標準エラーを合わせて返す（前後の空白を除く。環境変数は親から引き継ぐ）。
///
/// 終わるのを `waitUntilExit()` で待つと、その間は協調スレッドをふさぐ。git で準備するテストが並んで重なると協調スレッドが尽き、
/// テストのプロセスごと止まって、時間を測るほかのテストが落ちる（CI の 3 コアのランナーでは、3 つ重なるだけで止まる）。
/// `ProcessCommandRunner` で流し、終わりを待つ間はスレッドを返す（待つ間も出力を読み続け、取り消されたらコマンドを止める）
@discardableResult
func runShell(_ script: String) async throws -> String {
    let command = Command(
        executable: URL(fileURLWithPath: "/bin/sh"),
        // 標準エラーも標準出力のパイプに書かせ、出た順に合わせる
        arguments: ["-c", "exec 2>&1\n" + script],
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        timeout: .seconds(10 * 60)
    )
    let result = try await ProcessCommandRunner().run(command)
    let text = String(bytes: result.standardOutput, encoding: .utf8) ?? ""
    guard result.succeeded else { throw ShellFailure(output: text) }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ShellFailure: Error {
    var output: String
}
