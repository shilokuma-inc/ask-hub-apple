import Foundation

/// xcb のジョブの作業ツリーが、どの担当リポジトリのどのスロットか
public struct BuildSlot: Sendable, Equatable, Hashable {
    /// リポジトリ（`owner/name`）
    public var repository: String
    /// ループのスロット（`a` / `b`）
    public var slot: String

    public init(repository: String, slot: String) {
        self.repository = repository
        self.slot = slot
    }
}

/// xcb のジョブの `path`（作業ツリーのローカルパス）を、担当リポジトリのループのスロット（`<名前>-ralph-a` / `-b`）と照らす。
///
/// 対象はループのスロットのビルドだけ（Discussion #366 の Q6）。メインの checkout・制御用 worktree・
/// コンフリクト解消の一時 worktree・手で流したビルドは `nil`（GitHub には書かない。Mac の実行中の本数にだけ含める）。
/// `path` はローカルパスなので GitHub に書かず、ここで決めたリポジトリとスロットだけを書く
public struct BuildSlotResolver: Sendable {
    private let slots: [(path: String, slot: BuildSlot)]

    public init(repositories: [RepositoryConfig]) {
        slots = repositories.flatMap { repository in
            RepositoryConfig.loopSlots.flatMap { slot in
                let path = repository.slotWorktreePath(slot)
                let buildSlot = BuildSlot(repository: repository.fullName, slot: slot)
                // xcb はシンボリックリンクを解決したパス（zsh の `:A`）を書くので、解決した形とそのままの形の両方で照らす
                return Set([Self.normalized(path), Self.resolved(path)]).map { (path: $0, slot: buildSlot) }
            }
        }
    }

    /// `path` がスロットの worktree（かその中）ならリポジトリとスロット。それ以外は `nil`
    public func slot(forPath path: String) -> BuildSlot? {
        let candidates = Set([Self.normalized(path), Self.resolved(path)])
        return slots.first { entry in
            candidates.contains { $0 == entry.path || $0.hasPrefix(entry.path + "/") }
        }?.slot
    }

    /// `.` や `..`・末尾の `/` を除いた形
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashes
    }

    /// シンボリックリンクを解決した形。`URL.resolvingSymlinksInPath()` は `/private` を外すので `realpath(3)` を使う。
    /// まだ無いパス（スロットを作る前）は親のディレクトリを解決して名前を足す。親も解決できなければ `normalized` と同じ
    private static func resolved(_ path: String) -> String {
        if let real = realPath(path) {
            return real
        }
        let url = URL(fileURLWithPath: normalized(path))
        guard let parent = realPath(url.deletingLastPathComponent().path(percentEncoded: false)) else {
            return normalized(path)
        }
        return URL(fileURLWithPath: parent, isDirectory: true)
            .appending(path: url.lastPathComponent, directoryHint: .isDirectory)
            .path(percentEncoded: false)
            .trimmingTrailingSlashes
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer).trimmingTrailingSlashes
    }
}

private extension String {
    var trimmingTrailingSlashes: String {
        var path = self
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
