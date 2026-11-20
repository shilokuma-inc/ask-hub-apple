import Foundation

/// テストの準備で `/bin/sh -c` を流し、標準出力と標準エラーを合わせて返す（前後の空白を除く。環境変数は親から引き継ぐ）。
///
/// 終わるのを `waitUntilExit()` で待つと、その間は協調スレッドをふさぐ。git で準備するテストが並んで重なると協調スレッドが尽き、
/// テストのプロセスごと止まって、時間を測るほかのテストが落ちる（CI の 3 コアのランナーでは、3 つ重なるだけで止まる）。
/// 終わりの知らせを待つ間は、スレッドを返す
@discardableResult
func runShell(_ script: String) async throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardOutput = output
    process.standardError = output
    try await runUntilExit(process)
    let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw ShellFailure(output: text) }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `process` を起動し、終わるまで待つ。待つ間は協調スレッドを返す（`waitUntilExit()` で待たない理由は `runShell` を見る）
func runUntilExit(_ process: Process) async throws {
    let exited = AsyncStream<Void> { exit in
        process.terminationHandler = { _ in exit.finish() }
    }
    try process.run()
    for await _ in exited {}
}

struct ShellFailure: Error {
    var output: String
}
