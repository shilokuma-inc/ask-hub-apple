import AskHubBuild
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 対象のアプリのアイコンを取り出す元（本物は `GitAppIconSource`）
public protocol AppIconSource: Sendable {
    /// base（`repo.json` の `build.baseBranch`。nil なら既定のブランチ）の先頭のアイコンの元。見つからなければ nil
    func locate(_ repo: RepositoryFullName, base: String?) async throws -> AppIconLocator.Source?
    /// 元を PNG にする
    func render(_ source: AppIconLocator.Source, of repo: RepositoryFullName) async throws -> Data
}

/// 常時オンの Mac の clone から取り出し、`AppIconRenderer` で PNG にする
public struct GitAppIconSource: AppIconSource {
    public var workspace: GitRepositoryWorkspace
    public var renderer: AppIconRenderer

    public init(workspace: GitRepositoryWorkspace, renderer: AppIconRenderer) {
        self.workspace = workspace
        self.renderer = renderer
    }

    public func locate(_ repo: RepositoryFullName, base: String?) async throws -> AppIconLocator.Source? {
        try await workspace.locateAppIcon(repo, base: base)
    }

    /// 元のフォルダを、ビルドの一時フォルダの下に取り出して書き出す。取り出したものは書き出した後に消す
    public func render(_ source: AppIconLocator.Source, of repo: RepositoryFullName) async throws -> Data {
        let directory = renderer.tools.temporaryDirectory.appendingPathComponent("app-icon-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try await workspace.exportAppIcon(source, of: repo, to: directory)
        return try await renderer.render(folder)
    }
}

/// 対象のリポジトリのアプリのアイコンを、状態リポジトリに置く（`docs/renewal/architecture.md` の「対象のアプリのアイコン」）。
///
/// 司令塔が生きている印を書くときに `start()` を呼ぶ。前に確かめてから `interval` たったリポジトリ（起動し直した後は、すべてのリポジトリ）を、
/// 周の外で 1 つずつ確かめ、元のフォルダの tree が変わっていたら書き出して、`icon.png` と `repo.json` の `icon` を書く
public actor AppIconSync {
    nonisolated let context: CommanderContext
    nonisolated let source: any AppIconSource
    nonisolated let log: @Sendable (String) -> Void
    /// 1 つのリポジトリを確かめる間隔
    nonisolated let interval: TimeInterval
    /// リポジトリごとの、最後に確かめた時刻（確かめられなかったときも、次は `interval` の後にやり直す）
    private var checkedAt: [RepositoryFullName: Date] = [:]
    private var running = false

    /// 書く画像の大きさの上限（バイト。256px の PNG は 300 KB に収まる）
    static let maximumImageSize = 1_000_000

    public init(
        context: CommanderContext,
        source: any AppIconSource,
        log: @escaping @Sendable (String) -> Void,
        interval: Duration = .seconds(6 * 60 * 60)
    ) {
        self.context = context
        self.source = source
        self.log = log
        self.interval = TimeInterval(interval.components.seconds)
    }

    /// 確かめる時期のリポジトリを、周の外で確かめ始める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await refreshDue() }
    }

    /// 確かめる時期のリポジトリを、1 つずつ確かめる。確かめているときに呼ばれたら、何もしない
    func refreshDue() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let repositories: [RepositoryFullName]
        do {
            repositories = try await context.repositories()
        } catch {
            log("アプリのアイコンを確かめるリポジトリの一覧を読めない（\(error)）。次の生きている印のときにやり直す")
            return
        }
        for repo in repositories where isDue(repo) {
            do {
                try await refresh(repo)
            } catch {
                log("\(repo) のアプリのアイコンを確かめられない（\(error)）。次に確かめるときにやり直す")
            }
            checkedAt[repo] = context.now()
        }
    }

    private func isDue(_ repo: RepositoryFullName) -> Bool {
        guard let checked = checkedAt[repo] else { return true }
        return context.now().timeIntervalSince(checked) >= interval
    }

    /// 1 つのリポジトリのアイコンを確かめ、元が変わっていれば書き出して置く。書いたら true。
    /// 元は、Claude のジョブの写しと同じく base（ビルドを設定する前は既定のブランチ）から探す。元が見つからなくなっても、前のアイコンは残す
    @discardableResult
    func refresh(_ repo: RepositoryFullName) async throws -> Bool {
        let path = StatePath.repository(repo)
        // 対象から外したリポジトリは見ない（GitHub に触れない）
        guard let file = try await context.readable(RepositoryFile.self, at: path), !file.isRemoved,
              let found = try await source.locate(repo, base: file.build?.baseBranch) else { return false }
        if file.icon?.source == found.path, file.icon?.sourceTree == found.tree { return false }
        let png = try await source.render(found, of: repo)
        guard png.count <= Self.maximumImageSize else {
            throw AppIconRenderError("書き出した画像が大きすぎる（\(png.count) バイト）")
        }
        try await put(png, from: found, for: repo)
        log("\(repo) のアプリのアイコンを書いた（\(found.path)）")
        return true
    }

    /// 画像を書いてから repo.json を書く（逆だと、クライアントがまだ無い画像を読みに行く）。途中で止まっても、やり直せば同じになる
    nonisolated private func put(
        _ png: Data,
        from found: AppIconLocator.Source,
        for repo: RepositoryFullName
    ) async throws(CommanderError) {
        let path = StatePath.repository(repo)
        try await context.writingResult { () throws(CommanderError) in
            let image = try await writeImage(png, for: repo)
            let icon = RepositoryFile.AppIcon(source: found.path, sourceTree: found.tree, image: image, updatedAt: context.timestamp)
            do throws(StateFileStore.Failure) {
                try await context.files.update(RepositoryFile.self, at: path, message: "\(repo) のアプリのアイコンを書く") { file in
                    // 同じ元と画像なら書かない（やり直したとき）。時刻だけが違うものは同じとみなす
                    if let current = file.icon, current.source == icon.source, current.sourceTree == icon.sourceTree,
                       current.image == icon.image {
                        return false
                    }
                    file.icon = icon
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }

    /// `icon.png` を書き、その blob の sha を返す。同じ画像がもうあれば書かない
    nonisolated private func writeImage(_ png: Data, for repo: RepositoryFullName) async throws(CommanderError) -> String {
        let path = StatePath.appIcon(repo)
        do {
            let current = try await context.store.read(path)
            if let current, current.data == png { return current.sha }
            return try await context.store.write(path, data: png, replacing: current?.sha, message: "\(repo) のアプリのアイコンの画像を書く")
        } catch {
            throw .store(error)
        }
    }
}
