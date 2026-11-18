import AskHubProtocol
import AskHubStateStore
import Foundation

/// 片付けの候補を探す・選んだ候補を消す人の意図（`findCleanupCandidates`・`removeCleanupCandidates`）。
/// 司令塔は探しも消しもせず、その Mac の頼み（`cleanup/<mac>/requests.json`）に積むだけ。
/// その Mac のワーカー（`CleanupService`）が、元の意図の署名を確かめてから探し・消す
public struct CleanupRequestHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let (mac, request): (MacName, CleanupRequestsFile.Request)
        do {
            (mac, request) = try Self.request(from: envelope, at: context.timestamp)
        } catch {
            return .reject("片付けの意図の形が違う（\(error.detail)）")
        }
        guard try await context.read(MacFile.self, at: StatePath.mac(mac)) != nil else {
            return .reject("Mac \(mac) が登録されていない（ワーカーが一度も動いていない）")
        }
        let path = StatePath.cleanupRequests(mac)
        let message = "\(mac) の片付けを頼む（\(request.action.rawValue)）"
        do {
            if try await context.files.read(CleanupRequestsFile.self, at: path) == nil {
                _ = try await context.files.create(CleanupRequestsFile(requests: [request]), at: path, message: message)
            } else {
                _ = try await context.files.update(CleanupRequestsFile.self, at: path, message: message) { file in
                    // 前の周で積んだ（やり直し）なら書かない
                    guard !file.requests.contains(where: { $0.intent == request.intent }) else { return false }
                    file.requests = Array((file.requests + [request]).suffix(CleanupRequestsFile.keptRequests))
                    return true
                }
            }
        } catch .alreadyExists {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
        return .accept
    }

    static func request(
        from envelope: IntentEnvelope,
        at time: Timestamp
    ) throws(MalformedIntent) -> (MacName, CleanupRequestsFile.Request) {
        switch envelope.kind {
        case FindCleanupCandidatesIntent.kind:
            let find = try FindCleanupCandidatesIntent(envelope: envelope)
            return (find.mac, .init(intent: find.intent, action: .find, acceptedAt: time))
        default:
            let remove = try RemoveCleanupCandidatesIntent(envelope: envelope)
            let request = CleanupRequestsFile.Request(
                intent: remove.intent, action: .remove, candidates: remove.candidates, scannedAt: remove.scannedAt, acceptedAt: time
            )
            return (remove.mac, request)
        }
    }
}
