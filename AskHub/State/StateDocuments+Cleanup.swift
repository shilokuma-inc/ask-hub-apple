import AskHubProtocol
import Foundation

extension StateReader {
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
