import AskHubCommands
import Foundation

/// 撮影のワークフローの artifact（zip）を確かめて取り出す（本物は `UnzipArtifactExtractor`。テストでは差し替える）。
/// artifact は public のリポジトリの実行の成果物なので、データとして扱い、決まった形のものだけを取り出す
/// （`docs/renewal/store-screenshots.md` の「安全」）
public protocol StoreScreenshotArtifactExtracting: Sendable {
    /// `zip` を `directory` に取り出し、言語のフォルダごとの PNG（名前の順）を返す。形の違う zip は `ArtifactProblem` で断る
    func extract(_ zip: Data, into directory: URL) async throws -> [String: [URL]]
}

/// artifact を取り出せないわけ
public struct ArtifactProblem: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// macOS の `zipinfo`・`unzip` で、中身の名前と大きさを確かめてから取り出す
public struct UnzipArtifactExtractor: StoreScreenshotArtifactExtracting {
    /// 落とす zip の大きさの上限（template の artifact は 1 つ 4〜8 MB）
    public static let maximumZipBytes = 300 * 1024 * 1024
    /// 取り出した後の合計の大きさの上限
    public static let maximumExpandedBytes = 1024 * 1024 * 1024
    /// 1 枚の大きさの上限
    public static let maximumFileBytes = 20 * 1024 * 1024
    /// 1 つの zip の画像の数の上限（言語 50 × 10 枚）
    public static let maximumFiles = 500

    public var runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func extract(_ zip: Data, into directory: URL) async throws -> [String: [URL]] {
        guard zip.count <= Self.maximumZipBytes else { throw ArtifactProblem("artifact が \(Self.maximumZipBytes / 1_048_576) MB を超える") }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("artifact.zip")
        let output = directory.appendingPathComponent("files", isDirectory: true)
        try zip.write(to: archive, options: .atomic)
        defer { try? fileManager.removeItem(at: archive) }

        // 取り出す前に、中身の名前（`<言語>/<名前>.png` だけ）と合計の大きさを確かめる
        let names = try await lines(of: "/usr/bin/zipinfo", ["-1", archive.path], in: directory).filter { !$0.hasSuffix("/") }
        guard !names.isEmpty else { throw ArtifactProblem("artifact に画像が無い") }
        guard names.count <= Self.maximumFiles else { throw ArtifactProblem("artifact の画像が \(Self.maximumFiles) 枚を超える") }
        if let wrong = names.first(where: { !Self.isEntry($0) }) {
            throw ArtifactProblem("artifact に決まった形（<言語>/<名前>.png）でないもの（\(wrong.prefix(80))）がある")
        }
        let listing = try await lines(of: "/usr/bin/unzip", ["-l", archive.path], in: directory)
        guard let total = Self.expandedBytes(listing), total <= Self.maximumExpandedBytes else {
            throw ArtifactProblem("artifact を取り出した大きさが分からないか、\(Self.maximumExpandedBytes / 1_048_576) MB を超える")
        }
        _ = try await lines(of: "/usr/bin/unzip", ["-qq", "-o", archive.path, "-d", output.path], in: directory)

        // 取り出したものが、確かめた名前の、ふつうのファイル（シンボリックリンクでない）の PNG かを確かめる
        var folders: [String: [URL]] = [:]
        for name in names.sorted() {
            let file = output.appendingPathComponent(name)
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ArtifactProblem("\(name) がふつうのファイルでない") }
            guard let size = attributes[.size] as? Int, (1...Self.maximumFileBytes).contains(size) else {
                throw ArtifactProblem("\(name) の大きさが 0 か \(Self.maximumFileBytes / 1_048_576) MB を超える")
            }
            let handle = try FileHandle(forReadingFrom: file)
            let head = try handle.read(upToCount: 8) ?? Data()
            try handle.close()
            guard head == Self.pngSignature else { throw ArtifactProblem("\(name) が PNG でない") }
            let folder = String(name.split(separator: "/")[0])
            folders[folder, default: []].append(file)
        }
        return folders
    }

    /// `<言語>/<名前>.png`（言語は英数字・- _ で 20 文字まで、名前は英数字で始まり英数字・. _ - で 100 文字まで）
    static func isEntry(_ name: String) -> Bool {
        name.wholeMatch(of: #/[A-Za-z0-9_-]{1,20}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.png/#) != nil && !name.contains("..")
    }

    /// `unzip -l` の最後の行（`  4987593                     5 files`）の、取り出した合計の大きさ
    static func expandedBytes(_ listing: [String]) -> Int? {
        guard let last = listing.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return last.split(separator: " ").first.flatMap { Int($0) }
    }

    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func lines(of tool: String, _ arguments: [String], in directory: URL) async throws -> [String] {
        let executable = URL(fileURLWithPath: tool)
        let command = Command(executable: executable, arguments: arguments, workingDirectory: directory, timeout: .seconds(300))
        let result: CommandResult
        do {
            result = try await runner.run(command)
        } catch {
            throw ArtifactProblem("\(URL(fileURLWithPath: tool).lastPathComponent) を動かせない（\(error)）")
        }
        guard result.status == 0, !result.timedOut else {
            let reason = String(bytes: result.standardError.suffix(200), encoding: .utf8) ?? ""
            throw ArtifactProblem("\(URL(fileURLWithPath: tool).lastPathComponent) が失敗した（\(result.status)。\(reason)）")
        }
        return (String(bytes: result.standardOutput, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }
}
