import AskHubClient
import AskHubProtocol
import Foundation

// 共通リポジトリ app-kit の版を広げる・やめる意図。封筒に repo を書かず、版のタグとコミットに結びつける

extension StateIntentMapper {
    /// 広げられるのは、司令塔が見つけた版で、見たときのコミットのままのものだけ。ほかの版を広げている途中（止めたものを含む）なら、先にやめる。
    /// やめられるのは、広げている途中・止めた版だけ
    func supportsAppKitIntent(_ intent: HumanIntent) -> Bool {
        guard let file = index.appKit else {
            return false
        }
        switch intent {
        case let .rolloutAppKit(version, ref):
            guard file.releases.contains(where: { $0.version.rawValue == version && $0.ref == ref }) else {
                return false
            }
            guard let rollout = file.rollout else {
                return true
            }
            if rollout.version.rawValue == version {
                return rollout.state != .running
            }
            return rollout.state != .running && rollout.state != .failed

        case let .stopAppKitRollout(version, ref):
            guard let rollout = file.rollout, rollout.version.rawValue == version, rollout.ref == ref else {
                return false
            }
            return rollout.state == .running || rollout.state == .failed

        default:
            return false
        }
    }

    func appKitDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .rolloutAppKit(version, ref), let .stopAppKitRollout(version, ref):
            guard let parsed = AppKitVersion(rawValue: version), AttemptFile.isCommitSHA(ref) else {
                throw ClientServiceError(message: "app-kit の版の形が違います")
            }
            guard supportsAppKitIntent(intent) else {
                throw ClientServiceError(message: "app-kit の様子が変わりました。読み直してから押してください")
            }
            let release = AppKitReleaseTarget(version: parsed, ref: ref)
            if case .rolloutAppKit = intent {
                return .rolloutAppKit(release)
            }
            return .stopAppKitRollout(release)

        default:
            throw Self.unsupported
        }
    }
}
