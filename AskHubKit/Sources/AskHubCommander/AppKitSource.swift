import AskHubCommands
import AskHubProtocol
import CryptoKit
import Foundation

/// app-kit の `manifest.json`（写すファイルの一覧と、初めての入れ替えで外すファイル）
public struct AppKitManifest: Decodable, Equatable, Sendable {
    public struct Replace: Decodable, Equatable, Sendable {
        public var path: String
        /// このどれかがリポジトリにあれば、外さずに残す（クリエイティブ素材のワークフローが使う道具など）
        public var keepIfPresent: [String]?

        public init(path: String, keepIfPresent: [String]? = nil) {
            self.path = path
            self.keepIfPresent = keepIfPresent
        }
    }

    public var managed: [String]
    public var replaces: [Replace]

    public init(managed: [String], replaces: [Replace]) {
        self.managed = managed
        self.replaces = replaces
    }

    /// リポジトリの外や `.git` を指すパス・目印でない値を含まないか（app-kit は人の Claude Code のセッションで直すが、読む側でも確かめる）
    var problems: [String] {
        let paths = managed + replaces.flatMap { [$0.path] + ($0.keepIfPresent ?? []) }
        return paths.filter { !Self.isRepositoryPath($0) }.map { "manifest.json のパス \($0) の形が違う" }
            + (Set(managed).count == managed.count ? [] : ["manifest.json の managed が重なっている"])
            + (Set(managed).isDisjoint(with: replaces.map(\.path)) ? [] : ["manifest.json の managed と replaces が重なっている"])
    }

    /// リポジトリの直下からの相対パスで、`..`・`.git`・空の部品を含まない
    static func isRepositoryPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return (1...300).contains(path.utf8.count) && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }
            && path.unicodeScalars.allSatisfy { $0 == "/" || ($0.isASCII && allowed.contains($0)) }
    }
}

/// app-kit の 1 つの版の中身
public struct AppKitRelease: Equatable, Sendable {
    public var pin: AppKitFile.Pin
    public var manifest: AppKitManifest
    /// 写すファイル（パス → 版の目印を埋めた中身）
    public var managed: [String: String]
    /// 再利用ワークフロー（`.github/workflows/app-*.yml`）の手順の名前。外すワークフローにしか無い手順を見つけるのに使う
    public var steps: Set<String>
    /// 再利用ワークフロー `app-build.yml` のジョブの id（入れ替えた後のチェックの名前 `build / <id>` の後ろ）
    public var buildJobs: Set<String>

    public init(pin: AppKitFile.Pin, manifest: AppKitManifest, managed: [String: String], steps: Set<String>, buildJobs: Set<String>) {
        self.pin = pin
        self.manifest = manifest
        self.managed = managed
        self.steps = steps
        self.buildJobs = buildJobs
    }

    /// 写すファイルに版を埋める（app-kit の `tools/render-managed.sh` と同じ）
    static func render(_ text: String, pin: AppKitFile.Pin) -> String {
        text.replacingOccurrences(of: "{{APP_KIT_REF}}", with: pin.ref)
            .replacingOccurrences(of: "{{APP_KIT_VERSION}}", with: pin.version.rawValue)
    }

    /// 入れ替えた後に、呼ぶ側の `build.yml` が出すチェックの名前（`<呼ぶ側のジョブ> / <再利用ワークフローのジョブ>`）
    public var buildChecks: [String] {
        guard let caller = managed[".github/workflows/build.yml"] else { return [] }
        return WorkflowSetupEditor.jobIDs(in: caller).sorted().flatMap { job in buildJobs.sorted().map { "\(job) / \($0)" } }
    }
}

/// app-kit を読めなかったわけ
public enum AppKitSourceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// GitHub に届かない・git が時間内に終わらない
    case unavailable(String)
    /// 版のコミットが無い・ファイルの形が違う
    case malformed(String)

    public var description: String {
        switch self {
        case let .unavailable(detail): "app-kit を読めない（\(detail)）"
        case let .malformed(detail): "app-kit の中身の形が違う（\(detail)）"
        }
    }
}

/// app-kit を読む部品。版の中身はコミットで決まるので、読んだものを使い回してよい
public protocol AppKitSource: Sendable {
    /// 版の中身（写すファイルに版を埋めたもの・manifest・再利用ワークフローの手順）
    func release(_ pin: AppKitFile.Pin) async throws(AppKitSourceError) -> AppKitRelease
}

/// app-kit（public）を git で読む。REST の上限に数えない（`docs/renewal/app-kit.md` の「版」）。
///
/// 常時オンの Mac の作業用のフォルダに bare の写しを 1 つ持ち、要る版のコミットだけを浅く取る。トークンは使わない
public actor GitAppKitSource: AppKitSource {
    public struct Setup: Sendable {
        /// bare の写しを置くフォルダ
        public var directory: URL
        public var git: URL
        public var remote: URL
        public var timeout: Duration

        public init(
            directory: URL,
            git: URL = URL(fileURLWithPath: "/usr/bin/git"),
            remote: URL = URL(string: "https://github.com/\(AppKitPolicy.repository.rawValue).git")!,
            timeout: Duration = .seconds(5 * 60)
        ) {
            self.directory = directory
            self.git = git
            self.remote = remote
            self.timeout = timeout
        }
    }

    let setup: Setup
    let runner: any CommandRunning
    private var releases: [String: AppKitRelease] = [:]

    public init(setup: Setup, runner: any CommandRunning) {
        self.setup = setup
        self.runner = runner
    }

    public func release(_ pin: AppKitFile.Pin) async throws(AppKitSourceError) -> AppKitRelease {
        if let cached = releases[pin.ref], cached.pin == pin { return cached }
        guard AttemptFile.isCommitSHA(pin.ref) else { throw .malformed("版のコミット \(pin.ref) の形が違う") }
        try await fetch(pin.ref)
        let manifest: AppKitManifest
        do {
            manifest = try JSONDecoder().decode(AppKitManifest.self, from: Data(try await show(pin.ref, "manifest.json").utf8))
        } catch let error as AppKitSourceError {
            throw error
        } catch {
            throw .malformed("manifest.json を読めない（\(error)）")
        }
        if let problem = manifest.problems.first { throw .malformed(problem) }
        var managed: [String: String] = [:]
        for path in manifest.managed {
            managed[path] = AppKitRelease.render(try await show(pin.ref, "managed/\(path)"), pin: pin)
        }
        var steps: Set<String> = []
        var buildJobs: Set<String> = []
        let workflows = try await output(["ls-tree", "--name-only", pin.ref, ".github/workflows/"])
        for path in workflows.split(separator: "\n").map(String.init) where path.split(separator: "/").last?.hasPrefix("app-") == true {
            let text = try await show(pin.ref, path)
            steps.formUnion(WorkflowSteps.names(in: text))
            if path.hasSuffix("/app-build.yml") { buildJobs = WorkflowSetupEditor.jobIDs(in: text) }
        }
        let release = AppKitRelease(pin: pin, manifest: manifest, managed: managed, steps: steps, buildJobs: buildJobs)
        releases[pin.ref] = release
        return release
    }

    /// 版のコミットを取る（もう持っていれば取らない）
    func fetch(_ ref: String) async throws(AppKitSourceError) {
        if !FileManager.default.fileExists(atPath: setup.directory.appendingPathComponent("HEAD").path) {
            do {
                try FileManager.default.createDirectory(at: setup.directory, withIntermediateDirectories: true)
            } catch {
                throw .unavailable("\(setup.directory.lastPathComponent) を作れない（\(error.localizedDescription)）")
            }
            _ = try await output(["init", "--bare", "--quiet"])
        }
        if try await run(["cat-file", "-e", "\(ref)^{commit}"]).succeeded { return }
        _ = try await output(["fetch", "--quiet", "--depth", "1", "--no-tags", setup.remote.absoluteString, ref])
    }

    /// 版のファイルの中身（そのまま。前後の空白を除かない）
    func show(_ ref: String, _ path: String) async throws(AppKitSourceError) -> String {
        guard AppKitManifest.isRepositoryPath(path) else { throw .malformed("パス \(path) の形が違う") }
        return try await output(["show", "\(ref):\(path)"])
    }

    func output(_ arguments: [String]) async throws(AppKitSourceError) -> String {
        let result = try await run(arguments)
        guard result.succeeded else {
            let message = String(bytes: result.standardError, encoding: .utf8) ?? ""
            let detail = "git \(arguments.first ?? ""): \(message.split(separator: "\n").suffix(2).joined(separator: " "))"
            if result.timedOut { throw .unavailable("git \(arguments.first ?? "") が時間内に終わらない") }
            let unavailable = [
                "Could not resolve host", "Failed to connect", "timed out", "Connection reset", "returned error: 5", "early EOF", "SSL"
            ]
            throw unavailable.contains(where: message.contains) ? .unavailable(detail) : .malformed(detail)
        }
        guard let text = String(bytes: result.standardOutput, encoding: .utf8) else {
            throw .malformed("git \(arguments.first ?? "") の出力が UTF-8 でない")
        }
        return text
    }

    func run(_ arguments: [String]) async throws(AppKitSourceError) -> CommandResult {
        let command = Command(
            executable: setup.git,
            arguments: ["--git-dir", setup.directory.path] + arguments,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "core.hooksPath",
                "GIT_CONFIG_VALUE_0": "/dev/null",
                "GIT_CONFIG_KEY_1": "protocol.file.allow",
                "GIT_CONFIG_VALUE_1": "never"
            ],
            workingDirectory: setup.directory.deletingLastPathComponent(),
            timeout: setup.timeout
        )
        do {
            return try await runner.run(command)
        } catch {
            throw .unavailable("git を起動できない（\(error)）")
        }
    }
}

/// ワークフローの手順の名前を読む（行で読む。`steps:` の下の `- name:`）
enum WorkflowSteps {
    static func names(in text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- name:") else { continue }
            var name = String(trimmed.dropFirst("- name:".count)).trimmingCharacters(in: .whitespaces)
            if let comment = name.range(of: " #") { name = String(name[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            for quote in ["\"", "'"] where name.count >= 2 && name.hasPrefix(quote) && name.hasSuffix(quote) {
                name = String(name.dropFirst().dropLast())
            }
            if !name.isEmpty, !name.contains("${{") { names.insert(name) }
        }
        return names
    }
}

/// git の blob の sha（`git hash-object` と同じ）。リポジトリの tree の sha と比べ、中身を読まずに同じかを確かめる
enum GitBlob {
    static func sha(of text: String) -> String {
        let content = Data(text.utf8)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(content.count)\0".utf8))
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
