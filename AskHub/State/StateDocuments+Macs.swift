import AskHubProtocol
import Foundation

extension StateReader {
    /// ワーカーの生きている印（`macs/<mac>.json`）
    func readMacs() async throws(StateStoreError) -> Part<[MacFile]> {
        let entries = (try await store.listAll(Self.macsDirectory) ?? []).filter { $0.kind == .file && $0.name.hasSuffix(".json") }
        var part = Part<[MacFile]>(value: [])
        for read in await Self.inOrder(entries, { entry in await read(MacFile.self, at: entry.path) }) {
            read.value.map { part.value.append($0) }
            part.failures += read.failures
        }
        return part
    }

    /// 生きている印のある Mac の、片付けの候補（ワーカーが書く）と、受け付けた片付けの頼み（司令塔が書く）。
    /// 探したことのある Mac にだけある（無ければ、写しの tree で無いと分かるので要求を出さない）
    func readCleanup(into documents: inout StateDocuments) async {
        for mac in documents.macs.map(\.mac) {
            let candidates = await read(CleanupCandidatesFile.self, at: StatePath.cleanupCandidates(mac))
            let requests = await read(CleanupRequestsFile.self, at: StatePath.cleanupRequests(mac))
            documents.cleanupCandidates[mac] = candidates.value
            documents.cleanupRequests[mac] = requests.value
            documents.failures += candidates.failures + requests.failures
        }
    }
}
