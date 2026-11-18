import AskHubProtocol
import AskHubStateStore
import Foundation

/// 終わった（マージした・やめた）epic を、終わってから `age` たったら、状態リポジトリの `archive/` に移して畳む
/// （`docs/renewal/protocol.md` の「ファイルの置き方」）。生きている印を書いた後の司令塔の見回りで流す。
///
/// epic のフォルダ（`repos/<owner>/<repo>/epics/<epic>/`）と、依頼の添付（`attachments/<device>/<intent>/`）を、`archive/` の下の同じパスに移す。
/// 1 回の見回りの分は、1 つの書き込み（GitHub では 1 つのコミット）でまとめて移す（`StateStore.move`）。
/// 畳んだ epic は、クライアント・司令塔・ワーカーが読まなくなる（クライアントの「終わったもの」にも出ない。2026-11-18 に決めた）
public struct FinishedEpicArchive: Sendable {
    /// 終わってから畳むまでの時間の既定
    public static let defaultAge: TimeInterval = 30 * 24 * 60 * 60
    /// 1 回で畳む epic の数の上限（tree を作る要求を大きくしすぎない。残りは次の見回りで畳む）
    public static let batchLimit = 20

    public var context: CommanderContext
    public var age: TimeInterval
    public var log: @Sendable (String) -> Void

    public init(context: CommanderContext, age: TimeInterval = defaultAge, log: @escaping @Sendable (String) -> Void) {
        self.context = context
        self.age = age
        self.log = log
    }

    /// 1 回見回る。読めない・書けないときは何もせず、次の見回りでやり直す
    public func run() async {
        let due: [EpicFile]
        do {
            due = try await dueEpics()
        } catch {
            log("畳む epic を状態リポジトリから読めないので、次の見回りに回す（\(error)）")
            return
        }
        guard !due.isEmpty else { return }
        let names = due.map { "\($0.repo)/\($0.id)" }.joined(separator: "・")
        do {
            try await context.store.move(due.flatMap(Self.moves), message: "終わってから 30 日たった epic \(due.count) 本を archive/ に畳む")
            log("終わってから 30 日たった epic を archive/ に畳んだ: \(names)")
        } catch {
            log("終わってから 30 日たった epic を archive/ に畳めなかった（\(error)。\(names)）。次の見回りでやり直す")
        }
    }

    /// 終わってから `age` たった epic。古い順に `batchLimit` 本まで。読めない（知らない版など）epic は畳まない
    func dueEpics() async throws(CommanderError) -> [EpicFile] {
        let now = context.now()
        let snapshot: any StateStore
        do {
            snapshot = try await context.store.snapshot()
        } catch {
            throw .store(error)
        }
        // 多くのファイルを読むので、写しから読む（前に読んだ tree と blob を使い回す）
        let reader = CommanderContext(store: snapshot, mac: context.mac, now: context.now)
        var due: [(epic: EpicFile, finishedAt: Date)] = []
        for repo in try await reader.repositories() {
            for epic in try await reader.epics(of: repo, where: { $0.isFinished }) {
                let finishedAt = (epic.merge?.at ?? epic.updatedAt).date
                if now.timeIntervalSince(finishedAt) >= age { due.append((epic, finishedAt)) }
            }
        }
        return due.sorted { ($0.finishedAt, $0.epic.id) < ($1.finishedAt, $1.epic.id) }.prefix(Self.batchLimit).map(\.epic)
    }

    /// epic のフォルダと、依頼の添付（あれば）を畳む先
    static func moves(of epic: EpicFile) -> [StateMove] {
        var folders = [StatePath.epicDirectory(epic.repo, epic.id)]
        if let origin = epic.origin { folders.append(StatePath.attachments(device: origin.keyId, nonce: origin.nonce)) }
        return folders.map { StateMove(from: $0, to: StatePath.archived($0)) }
    }
}
