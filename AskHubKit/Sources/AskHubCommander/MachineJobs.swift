import AskHubProtocol
import AskHubStateStore
import Foundation

// 司令塔とワーカーで共通の、ジョブの読み方と生きている印の書き方

extension CommanderContext {
    /// `mac` が実装を受け持つ epic（開始のときに選ばれた、終わっていない epic）のすべてのジョブ。
    /// 引き受けるジョブを選ぶのに使う（依存の成功と、同時の上限の判断に、ほかの状態のジョブも要る）。読めない epic・ジョブは飛ばす
    public func jobsOfEpics(on mac: MacName) async throws(CommanderError) -> [JobFile] {
        var jobs: [JobFile] = []
        for repo in try await repositories() {
            for epic in try await epics(of: repo, where: { $0.mac == mac && ![.merged, .abandoned].contains($0.stage) }) {
                jobs += try await jobList(repo, epic: epic.id).jobs
            }
        }
        return jobs
    }

    /// 書き手が 1 つのファイル（生きている印など）を、無ければ作り、あれば置き換える
    public func put<File: StateFile>(_ file: File, at path: String, message: String) async throws(CommanderError) {
        do {
            if try await files.read(File.self, at: path) == nil {
                try await files.create(file, at: path, message: message)
            } else {
                try await files.update(File.self, at: path, message: message) {
                    $0 = file
                    return true
                }
            }
        } catch .alreadyExists {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
    }
}

extension CommanderLoop.MachineStatus {
    /// `macs/<mac>.json` に書く生きている印
    public func macFile(
        mac: MacName,
        kind: MacKind,
        at time: Timestamp,
        versions: MacFile.Versions,
        capacity: MacFile.Capacity
    ) -> MacFile {
        MacFile(
            mac: mac,
            kind: kind,
            seenAt: time,
            versions: versions,
            diskFreeGB: diskFreeGB,
            load: load,
            capacity: capacity,
            selfCheck: selfCheck
        )
    }
}

/// ジョブの元になった人の意図の署名を確かめてから実行する（ワーカー。`docs/renewal/protocol.md` の「ジョブ」）。
/// 確かめられなければ実行せず、想定外の失敗として人に渡す（黙って止まらない）
public struct OriginCheckedRunner: JobRunning {
    public var context: CommanderContext
    public var verifier: IntentVerifier
    public var runner: any JobRunning

    public init(context: CommanderContext, verifier: IntentVerifier, runner: any JobRunning) {
        self.context = context
        self.verifier = verifier
        self.runner = runner
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        guard try await context.envelope(of: job.origin, verifier: verifier) != nil else {
            let origin = job.origin.map { "\($0.keyId)/\($0.nonce)" } ?? "無い"
            let message = "ジョブの元になった人の意図（\(origin)）が無い・署名を確かめられないので、実行しない"
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: message))
        }
        return try await runner.execute(job)
    }
}
