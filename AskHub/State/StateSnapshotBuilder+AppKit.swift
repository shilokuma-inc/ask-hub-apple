import AskHubProtocol
import Foundation

// MARK: - 共通リポジトリ app-kit

extension StateSnapshotBuilder {
    /// `app-kit.json` を画面の形にする。司令塔がまだ書いていなければ nil
    func appKitOverview(index: inout StateIndex) -> AppKitOverview? {
        guard let file = documents.appKit else {
            return nil
        }
        index.appKit = file
        let rollout = file.rollout.map { rollout in
            AppKitOverview.Rollout(
                version: rollout.version.rawValue,
                ref: rollout.ref,
                state: Self.state(of: rollout.state),
                pilot: rollout.pilot.rawValue,
                targets: rollout.targets.map(Self.target),
                problem: rollout.problem,
                startedAt: rollout.startedAt.date,
                updatedAt: rollout.updatedAt.date
            )
        }
        return AppKitOverview(
            checkedAt: file.checkedAt?.date,
            problem: file.problem,
            releases: file.releases.map { .init(version: $0.version.rawValue, ref: $0.ref, changes: $0.changes, foundAt: $0.foundAt.date) },
            adoptionVersion: file.adoption?.version.rawValue,
            rollout: rollout,
            templates: file.templates.map { .init(repository: $0.repo.rawValue, installed: $0.appKit.map(Self.installation)) },
            rejection: appKitRejection(after: file.rollout?.updatedAt)
        )
    }

    /// 対象のリポジトリの app-kit の様子。`app-kit.json` が無ければ nil
    func repositoryAppKit(of file: RepositoryFile) -> RepositoryAppKit? {
        guard let state = documents.appKit else {
            return nil
        }
        return RepositoryAppKit(
            installed: file.appKit.map(Self.installation),
            rolloutVersion: state.rollout?.version.rawValue,
            rolloutTarget: state.rollout?.target(file.repo).map(Self.target)
        )
    }

    static func installation(_ appKit: RepositoryFile.AppKit) -> AppKitInstallation {
        AppKitInstallation(
            version: appKit.version?.rawValue,
            ref: appKit.ref,
            installedAt: appKit.installedAt?.date,
            drift: appKit.drift?.problems ?? [],
            driftFoundAt: appKit.drift?.foundAt.date
        )
    }

    private static func target(_ target: AppKitFile.Target) -> AppKitOverview.Target {
        let state: AppKitTargetState = switch target.state {
        case .open: .open
        case .verifying: .verifying
        case .done: .done
        case .failed: .failed
        case .skipped: .skipped
        case .stopped: .stopped
        }
        return AppKitOverview.Target(
            repository: target.repo.rawValue,
            isTemplate: target.kind == .template,
            state: state,
            pullRequest: target.pullRequest,
            problem: target.problem,
            updatedAt: target.updatedAt.date
        )
    }

    private static func state(of state: AppKitFile.Rollout.State) -> AppKitRolloutState {
        switch state {
        case .running: .running
        case .failed: .failed
        case .finished: .finished
        case .stopped: .stopped
        }
    }

    /// 最後に送った「広げる」「やめる」が断られた理由。断った後に広げる様子が書き直されていれば出さない
    private func appKitRejection(after updatedAt: Timestamp?) -> String? {
        let kinds: Set = [RolloutAppKitIntent.kind, StopAppKitRolloutIntent.kind]
        guard let last = documents.sentIntents.first(where: { kinds.contains($0.envelope.kind) }),
              let consumed = last.consumed, consumed.result == .rejected else {
            return nil
        }
        if let updatedAt, updatedAt.date > consumed.consumedAt.date {
            return nil
        }
        return consumed.reason ?? "理由は書かれていません"
    }
}
