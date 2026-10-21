import Foundation
@testable import OrchestratorKit
import Testing

/// 本物の `claude` は起動せず、`/bin/sh` などの無害なコマンドで確かめる
struct LocalLoopRuntimeTests {
    /// 一時ディレクトリの中に checkout と制御用 worktree を作る
    private func makeRepository() throws -> (RepositoryConfig, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLoopRuntimeTests-\(UUID().uuidString)")
        let checkout = root.appendingPathComponent("ask-hub-apple")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        return (RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: checkout.path), root)
    }

    /// 条件が真になるまで最大 5 秒待つ
    private func waitUntil(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func readsStateFileInControlWorktree() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()
        #expect(await runtime.status(of: repository) == .idle)

        let stateFile = URL(fileURLWithPath: repository.controlWorktreePath).appendingPathComponent(LocalLoopRuntime.stateFileRelativePath)
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nactive: true\n---\n".utf8).write(to: stateFile)
        #expect(await runtime.status(of: repository) == LoopStatus(stateFileExists: true, processAlive: false))
    }

    @Test func treatsStateFileAsStaleWhenRecordedProcessIsGone() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        let stateFile = control.appendingPathComponent(LocalLoopRuntime.stateFileRelativePath)
        let pidFile = control.appendingPathComponent(LocalLoopRuntime.pidFileRelativePath)
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nactive: true\n---\n".utf8).write(to: stateFile)
        let runtime = LocalLoopRuntime()

        // 生きているプロセス（このテスト自身）なら、ループは動いている
        try Data("\(getpid())\n".utf8).write(to: pidFile)
        #expect(await runtime.status(of: repository) == LoopStatus(stateFileExists: true, processAlive: false))

        // 終わったプロセスの PID なら、state ファイルは残っていても止まっている
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try Data("\(finished.processIdentifier)".utf8).write(to: pidFile)
        #expect(await runtime.status(of: repository) == LoopStatus(stateFileExists: false, processAlive: false, stalled: true))

        // PID ファイルが読めなければ判断せず、state ファイルを信じる
        try Data("not a pid".utf8).write(to: pidFile)
        #expect(await runtime.status(of: repository) == LoopStatus(stateFileExists: true, processAlive: false))
    }

    @Test func passesAdditionalEnvironmentToCommands() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime(environment: ["ASKHUB_TRUSTED_AUTHORS": "mrs1669,someone"])
        let result = try await runtime.run(["/usr/bin/env"], input: "", for: repository, timeout: .seconds(10))
        #expect(result.output.contains("ASKHUB_TRUSTED_AUTHORS=mrs1669,someone"))
        // 継承した環境変数も残る
        #expect(result.output.contains("PATH="))
    }

    @Test func passesPerLaunchEnvironmentOverConfiguredOne() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime(environment: ["ASKHUB_TRUSTED_AUTHORS": "mrs1669", "ASKHUB_RESUME_REASON": "configured"])

        // 起動ごとの環境変数は、初期化で渡した値より優先し、ほかの値は残す
        try await runtime.launch(
            ["/bin/sh", "-c", #"printf '%s %s' "$ASKHUB_RESUME_REASON" "$ASKHUB_TRUSTED_AUTHORS" > env.tmp; mv env.tmp env.txt"#],
            environment: ["ASKHUB_RESUME_REASON": "decision-log"],
            for: repository
        )
        let output = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("env.txt")
        #expect(try await waitUntil { FileManager.default.fileExists(atPath: output.path) })
        #expect(try String(contentsOf: output, encoding: .utf8) == "decision-log mrs1669")
    }

    @Test func reportsUnknownWhenControlWorktreeIsUnreadable() async throws {
        let (repository, root) = try makeRepository()
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: control.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: control.path)
            try? FileManager.default.removeItem(at: root)
        }

        // アクセス権が無いときは「無い」ではなく「確かめられない」
        #expect(await LocalLoopRuntime().status(of: repository) == LoopStatus(stateFileExists: nil, processAlive: false))
    }

    @Test func readsEpicSnapshotFromWorktree() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        let gitDirectory = root.appendingPathComponent("main.git/worktrees/ctl")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        // worktree の `.git` は gitdir を指すファイル
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: control.appendingPathComponent(".git"))
        try Data("ref: refs/heads/epic/mvp\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        try Data("- [x] A".utf8).write(to: control.appendingPathComponent(".claude/ralph-goal.local.md"))

        let snapshot = await LocalLoopRuntime().epicSnapshot(of: repository)
        #expect(snapshot == EpicSnapshot(branch: "epic/mvp", goal: "- [x] A", state: nil))

        // 起動スクリプトが残したゴール元の Discussion の番号を読む
        try Data("12\n".utf8).write(to: control.appendingPathComponent(".claude/askhub-bootstrap.local.txt"))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).discussion == 12)
        try Data("not a number".utf8).write(to: control.appendingPathComponent(".claude/askhub-bootstrap.local.txt"))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).discussion == nil)

        // 準備の結果 goal にタスクが無かった Discussion の番号を読み、知らせた後に消す
        try Data("12\n".utf8).write(to: control.appendingPathComponent(LocalLoopRuntime.noTasksFileRelativePath))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).noTasksDiscussion == 12)
        await LocalLoopRuntime().clearNoTasksMarker(of: repository)
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).noTasksDiscussion == nil)

        // 起動スクリプトが完了語を残していれば、ループを始められる状態まで準備できている
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).loopPrepared == false)
        try Data("DONE\n".utf8).write(to: control.appendingPathComponent(".claude/askhub-promise.local.txt"))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).loopPrepared)

        // detached HEAD ではブランチが無い
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).branch == nil)
    }

    @Test func readsUsageLimitFromLatestLogLink() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let runtime = LocalLoopRuntime(loopLogDirectory: logs)
        #expect(await runtime.usageLimitReset(of: repository) == nil)

        // 起動スクリプトは最新のログを `<リポジトリ名>-latest.log` のリンクで指す
        let log = logs.appendingPathComponent("ask-hub-apple-loop-20261005-101145.log")
        // ログの更新時刻（今）から 1 時間後に解除される
        let reset = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded(.down))
        try Data("Claude AI usage limit reached|\(Int(reset.timeIntervalSince1970))\n".utf8).write(to: log)
        try FileManager.default.createSymbolicLink(
            at: logs.appendingPathComponent("ask-hub-apple-latest.log"),
            withDestinationURL: log
        )
        #expect(await runtime.usageLimitReset(of: repository) == reset)

        // 時刻だけの解除の時刻は、ログの更新時刻を基準に読む
        try Data("You've hit your session limit · resets 12pm (UTC)\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: log.path)
        #expect(await runtime.usageLimitReset(of: repository) == Date(timeIntervalSince1970: 12 * 60 * 60))

        try Data("ループを起動します\n".utf8).write(to: log)
        #expect(await runtime.usageLimitReset(of: repository) == nil)
    }

    @Test func findsAndTerminatesLoopWhoseIterationIsTooLong() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        let stateFile = control.appendingPathComponent(LocalLoopRuntime.stateFileRelativePath)
        let pidFile = control.appendingPathComponent(LocalLoopRuntime.pidFileRelativePath)
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let loop = Process()
        loop.executableURL = URL(fileURLWithPath: "/bin/sleep")
        loop.arguments = ["30"]
        try loop.run()
        defer { loop.terminate() }
        // 起動スクリプトと同じく、プロセスの起動の後に PID を書く
        try Data("\(loop.processIdentifier)\n".utf8).write(to: pidFile)
        try Data("---\niteration: 2\n---\n".utf8).write(to: stateFile)
        let runtime = LocalLoopRuntime(killGracePeriod: .milliseconds(100))
        let now = Date()

        // 周回が始まったばかりなら止めない
        #expect(await runtime.hungLoop(of: repository, timeout: .seconds(90 * 60), now: now) == nil)

        // state ファイルが 90 分より前から書き直されていなければ、固まったとみなす
        let started = now.addingTimeInterval(-91 * 60)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: stateFile.path)
        let hung = try #require(await runtime.hungLoop(of: repository, timeout: .seconds(90 * 60), now: now))
        #expect(hung.pid == loop.processIdentifier)

        // PID ファイルがプロセスの起動より前に書かれていたら、PID が再利用された別のプロセスなので止めない
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: pidFile.path)
        #expect(await runtime.hungLoop(of: repository, timeout: .seconds(90 * 60), now: now) == nil)

        // 見つけたときと起動時刻が違う（PID が再利用された）なら、シグナルを送らない
        let reused = HungLoop(pid: hung.pid, iterationStartedAt: hung.iterationStartedAt, processStartedAt: Date(timeIntervalSince1970: 0))
        await runtime.terminate(reused)
        #expect(loop.isRunning)

        await runtime.terminate(hung)
        #expect(try await waitUntil { !loop.isRunning })
    }

    @Test func readsBranchFromGitDirectory() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = URL(fileURLWithPath: repository.checkoutPath)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/develop\n".utf8).write(to: checkout.appendingPathComponent(".git/HEAD"))

        #expect(LocalLoopRuntime.currentBranch(of: checkout) == "develop")
        #expect(LocalLoopRuntime.currentBranch(of: root) == nil)
    }

    @Test func runsCommandInCheckoutAndTracksUntilExit() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        // 引数はシェルを経由せずに渡るので、空白を含んでも 1 つの引数のまま
        try await runtime.launch(["/bin/sh", "-c", #"pwd -P > out.txt; printf %s "$1" > arg.txt; sleep 1"#, "sh", "a b"], for: repository)
        #expect(await runtime.status(of: repository).processAlive)
        #expect(try await waitUntil { await !runtime.status(of: repository).processAlive })

        let checkout = URL(fileURLWithPath: repository.checkoutPath)
        let workingDirectory = try String(contentsOf: checkout.appendingPathComponent("out.txt"), encoding: .utf8)
        // 一時ディレクトリは /var → /private/var のシンボリックリンクを含むので、実体のパスで比べる
        let resolved = try #require(realpath(checkout.path, nil))
        defer { free(resolved) }
        #expect(workingDirectory.trimmingCharacters(in: .newlines) == String(cString: resolved))
        #expect(try String(contentsOf: checkout.appendingPathComponent("arg.txt"), encoding: .utf8) == "a b")
    }

    @Test func runCollectsOutputAndExitStatus() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // 標準出力と標準エラーをまとめて受け取り、引数は 1 つのまま渡る
        let result = try await LocalLoopRuntime().run(
            ["/bin/sh", "-c", #"printf '%s\n' "$1"; echo err >&2; exit 3"#, "sh", "ASKHUB_DISCUSSION_URL: a b"],
            input: "",
            for: repository,
            timeout: .seconds(10)
        )
        #expect(result.status == 3)
        #expect(result.output.contains("ASKHUB_DISCUSSION_URL: a b\n"))
        #expect(result.output.contains("err"))
    }

    @Test func runPassesInputThroughStandardInput() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // パイプの容量（64 KB 程度）より大きな入力でも止まらない
        let input = String(repeating: "依頼の本文。", count: 20_000)
        let result = try await LocalLoopRuntime().run(["/usr/bin/wc", "-c"], input: input, for: repository, timeout: .seconds(10))
        #expect(result.status == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(Data(input.utf8).count))
    }

    @Test func runKeepsOnlyTailOfLargeOutput() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // 上限を超える出力でも、末尾（URL の行）は残り、文字の途中で切れても文字列にできる
        let script = #"yes あいう | head -c 1500001; echo; echo "ASKHUB_DISCUSSION_URL: https://github.com/o/r/discussions/1""#
        let result = try await LocalLoopRuntime().run(["/bin/sh", "-c", script], input: "", for: repository, timeout: .seconds(30))
        #expect(result.status == 0)
        // 保持するのは上限まで（壊れた文字の置き換えで数バイト増えることはある）
        #expect(result.output.utf8.count <= LocalLoopRuntime.maxOutputBytes + 8)
        #expect(result.output.hasSuffix("ASKHUB_DISCUSSION_URL: https://github.com/o/r/discussions/1\n"))
    }

    /// 子プロセス（`sleep 30`）の終了を待たずに戻ったとみなす上限。
    /// CI のランナーではテストのプロセス全体が 5 秒ほど止まることがあるので、ふだんの所要時間（1 秒未満）より大きく取る
    private static let returnLimit: Duration = .seconds(10)

    @Test func runStopsCommandAfterTimeout() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let start = ContinuousClock.now
        let result = try await LocalLoopRuntime().run(["/bin/sleep", "30"], input: "", for: repository, timeout: .milliseconds(300))
        #expect(result.status != 0)
        #expect(ContinuousClock.now - start < Self.returnLimit)
    }

    @Test func runKillsCommandThatIgnoresSIGTERM() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let start = ContinuousClock.now
        // sh が止まっても子の sleep がパイプを持ち続けるので、読み切りの上限も短くする
        let runtime = LocalLoopRuntime(killGracePeriod: .milliseconds(300), outputDrainTimeout: .milliseconds(300))
        let result = try await runtime.run(
            ["/bin/sh", "-c", "trap '' TERM; sleep 30"],
            input: "",
            for: repository,
            timeout: .milliseconds(300)
        )
        #expect(result.status != 0)
        #expect(ContinuousClock.now - start < Self.returnLimit)
    }

    @Test func runReturnsEvenIfChildKeepsPipeOpen() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // 子プロセス（sleep）がパイプを持ったまま残っても、決めた時間で読み切りをやめて戻る
        let start = ContinuousClock.now
        let result = try await LocalLoopRuntime(outputDrainTimeout: .milliseconds(500)).run(
            ["/bin/sh", "-c", "sleep 30 & echo done"],
            input: "",
            for: repository,
            timeout: .seconds(10)
        )
        #expect(result.status == 0)
        #expect(result.output.contains("done"))
        #expect(ContinuousClock.now - start < Self.returnLimit)
    }

    @Test func resolvesRelativeExecutableFromPath() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        try await runtime.launch(["touch", "launched"], for: repository)
        let marker = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("launched")
        #expect(try await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
    }

    @Test func throwsWhenExecutableIsMissing() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        await #expect(throws: (any Error).self) {
            try await runtime.launch(["/nonexistent/start-loop"], for: repository)
        }
        #expect(await runtime.status(of: repository) == .idle)
    }
}

// MARK: - 制限時間を過ぎたコマンドの子孫

extension LocalLoopRuntimeTests {
    /// コマンドが `child.pid` に書いた子孫の PID
    private func recordedChildPID(in repository: RepositoryConfig) throws -> pid_t {
        let file = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("child.pid")
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    @Test func runStopsDescendantsAfterTimeout() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // スクリプトが起動した claude の代わりに、子の sleep を置く。親に SIGTERM を送るだけでは、子は動き続ける
        let result = try await LocalLoopRuntime(killGracePeriod: .milliseconds(300), outputDrainTimeout: .milliseconds(300)).run(
            ["/bin/sh", "-c", "sleep 30 & echo $! > child.pid; wait"],
            input: "",
            for: repository,
            timeout: .milliseconds(500)
        )
        #expect(result.status != 0)
        let child = try recordedChildPID(in: repository)
        #expect(try await waitUntil { kill(child, 0) != 0 })
    }

    @Test func runKillsDescendantsThatIgnoreSIGTERMAfterCommandExits() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // コマンド（sh）は SIGTERM ですぐ終わるが、孫の sleep は SIGTERM を無視する。猶予の後に SIGKILL で止める
        let result = try await LocalLoopRuntime(killGracePeriod: .milliseconds(300), outputDrainTimeout: .milliseconds(300)).run(
            ["/bin/sh", "-c", "(trap '' TERM; sleep 30 & echo $! > child.pid; wait) & wait"],
            input: "",
            for: repository,
            timeout: .milliseconds(500)
        )
        #expect(result.status != 0)
        let grandchild = try recordedChildPID(in: repository)
        #expect(try await waitUntil { kill(grandchild, 0) != 0 })
    }

    @Test func runLetsScriptCleanUpWhenItTrapsSIGTERM() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // scripts/orchestrator/*.sh と同じ形: EXIT で後片付けし、SIGTERM では exit して EXIT の trap を走らせる。
        // 子（コマンド置換の中の sleep）も止まるので、後片付けまで進む
        let script = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("script.sh")
        try """
            #!/bin/bash
            set -euo pipefail
            trap 'echo cleaned > cleaned.txt' EXIT
            trap 'exit 143' TERM
            OUTPUT=$(sleep 30 | cat)
            """.write(to: script, atomically: true, encoding: .utf8)
        let result = try await LocalLoopRuntime(killGracePeriod: .seconds(3), outputDrainTimeout: .milliseconds(300)).run(
            ["/bin/bash", script.path],
            input: "",
            for: repository,
            timeout: .milliseconds(500)
        )
        #expect(result.status == 143)
        let cleaned = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("cleaned.txt")
        #expect(FileManager.default.fileExists(atPath: cleaned.path))
    }
}
