import AskHubClient
import Foundation

// 片付けの候補を探す・選んだ候補を消す意図。Mac ごとの頼みで、封筒に repo・target を書かない

extension StateIntentMapper {
    /// 探すのは生きている印のある Mac だけ。消すのは、探し終えた候補だけ（探した時刻を一緒に送り、その後に探し直していればワーカーが消さない）
    func cleanupDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        if case let .cleanUp(macID, _) = intent, index.macs[macID]?.cleanupUnknown == true {
            throw Self.cleanupUnknown
        }
        if case let .findCleanupCandidates(macID) = intent, index.macs[macID]?.cleanupUnknown == true {
            throw Self.cleanupUnknown
        }
        switch intent {
        case .findCleanupCandidates(let macID):
            guard let mac = index.macs[macID] else { throw ClientServiceError(message: "Mac が見つかりません。読み直してから探してください") }
            return .findCleanupCandidates(mac: mac.name)

        case let .cleanUp(macID, candidateIDs):
            guard !candidateIDs.isEmpty else { throw ClientServiceError(message: "消す候補を選んでください") }
            guard let mac = index.macs[macID], let scannedAt = mac.cleanupScannedAt else {
                throw ClientServiceError(message: "片付けの候補をまだ探していません。探してから選んでください")
            }
            return .removeCleanupCandidates(mac: mac.name, scannedAt: scannedAt, candidates: candidateIDs)

        default:
            throw Self.unsupported
        }
    }

    /// 片付けのファイルを読めず、済ませたかどうかが分からないとき（重ねて頼まない）
    static let cleanupUnknown = ClientServiceError(message: "片付けの状態を読めませんでした。読み直してから送ってください")
}
