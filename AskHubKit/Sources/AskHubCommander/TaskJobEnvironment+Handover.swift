import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// 人がする作業で渡されたファイルを置いた場所。実装の Claude に読ませる
public struct HandedOverFile: Equatable, Sendable {
    /// 人がする作業の id と題
    public var humanTask: String
    public var title: String
    /// 置いたファイルのパス（Claude が読めるフォルダの中）
    public var path: String

    public init(humanTask: String, title: String, path: String) {
        self.humanTask = humanTask
        self.title = title
        self.path = path
    }
}

/// 渡されたファイルを置いたフォルダ（Claude に読ませるフォルダ）と、置いたファイル
struct PlacedHandover: Equatable {
    var directory: URL
    var files: [HandedOverFile]
}

/// 署名した意図と照らし合わせた、渡されたファイルの中身
private struct HandoverContent {
    var task: GoalFile.HumanTask
    var file: RequestAttachment
    var data: Data
}

/// 人がする作業（`file`）で渡されたファイルを、それに依存するタスクの実装のときに置く（`docs/renewal/flows.md` の「人がする作業」）
extension TaskJobEnvironment {
    /// タスクが前提にする人がする作業（`file`）で渡されたファイルを、Claude が読めるフォルダに `<フォルダ>/<作業の id>/<名前>` で置く。
    /// 前提に `file` の作業が無ければ nil。
    ///
    /// ゴールの `done` が指す人の意図（ジョブの元の意図ではなく、ファイルを渡した人の意図）を読み直して署名を確かめ、その封筒の大きさとハッシュと
    /// 状態リポジトリの中身を照らし合わせる。合わなければ渡さずに失敗にする（受け付けた後に置き換えられたファイルを読ませない）
    func placeHandover(for target: TaskTarget) async throws(TaskJobExit) -> PlacedHandover? {
        let humanTasks = target.goal.humanTasks.filter { target.task.dependsOn.contains($0.id) && $0.handover.kind == .file }
        guard !humanTasks.isEmpty else { return nil }
        let verifier: IntentVerifier
        do {
            verifier = try await self.verifier()
        } catch {
            throw .state(error)
        }
        var contents: [HandoverContent] = []
        for humanTask in humanTasks {
            contents.append(try await handedOver(humanTask, in: target, verifier: verifier))
        }
        let git = git
        let directory = try await workspace { () throws(WorkspaceError) in
            try await git.handoverDirectory(epic: target.epic.id, task: target.task.id)
        }
        var files: [HandedOverFile] = []
        for content in contents {
            // 名前は、受け付けたときにパスの区切りを含まないことを確かめている
            let folder = directory.appendingPathComponent(content.task.id, isDirectory: true)
            let url = folder.appendingPathComponent(content.file.name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try content.data.write(to: url, options: .atomic)
            } catch {
                throw .fail(.unexpected, "人がする作業 \(content.task.id) で渡されたファイルを置けない（\(error.localizedDescription)）")
            }
            files.append(HandedOverFile(humanTask: content.task.id, title: content.task.title, path: url.path))
        }
        return PlacedHandover(directory: directory, files: files)
    }

    /// 人がする作業で渡されたファイルの参照と中身。署名した `humanTaskDone` の大きさとハッシュと合うときだけ返す
    private func handedOver(
        _ humanTask: GoalFile.HumanTask,
        in target: TaskTarget,
        verifier: IntentVerifier
    ) async throws(TaskJobExit) -> HandoverContent {
        let what = "人がする作業 \(humanTask.id) で渡されたファイル"
        guard humanTask.state == .done, let done = humanTask.done else {
            throw .fail(.unexpected, "人がする作業 \(humanTask.id) がまだ終わっていないので、タスク \(target.task.id) を実装できない")
        }
        let envelope: IntentEnvelope?
        do {
            envelope = try await context.envelope(of: done.intent, verifier: verifier)
        } catch {
            throw .state(error)
        }
        guard let envelope, let intent = try? HumanTaskDoneIntent(envelope: envelope), intent.target.repo == target.epic.repo,
              intent.target.epic == target.epic.id, intent.target.task == humanTask.id, let file = intent.file, done.file == file else {
            throw .fail(.unexpected, "\(what)の意図が無い・署名が合わない・ゴールの記録と合わないので、Claude に渡さない")
        }
        let blob: StoredBlob?
        do {
            let path = StatePath.attachment(device: intent.intent.keyId, nonce: intent.intent.nonce, number: file.number)
            blob = try await context.store.read(path)
        } catch {
            throw .state(.store(error))
        }
        guard let data = blob?.data else { throw .fail(.unexpected, "\(what)（\(file.name)）が状態リポジトリに無い") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == file.size, digest == file.sha256 else {
            throw .fail(.unexpected, "\(what)（\(file.name)）の大きさかハッシュが、署名した意図と合わないので、Claude に渡さない")
        }
        return HandoverContent(task: humanTask, file: file, data: data)
    }
}
