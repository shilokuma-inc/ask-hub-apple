import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// app-kit の版を広げる意図（`rolloutAppKit`）を受け付け、`app-kit.json` の `rollout` を始める（進めるのは `AppKitRolloutDriver`）。
///
/// - 司令塔が見つけた版で、人が見たときのコミットのままのときだけ受け付ける
/// - ほかの版を広げている途中（`running`・`failed`）なら断る（先にやめる）
/// - 同じ版にもう一度送ると、止めたところからやり直す（開いたままの PR は追い直し、ほかの相手は確かめ直す。ずれたリポジトリにも PR を出し直す）
public struct RolloutAppKitHandler: IntentHandler {
    public var admin: AdminGitHub?
    /// 試しの 1 本（司令塔の設定。既定は `AppKitPolicy.defaultPilot`）
    public var pilot: RepositoryFullName

    public init(admin: AdminGitHub?, pilot: RepositoryFullName = AppKitPolicy.defaultPilot) {
        self.admin = admin
        self.pilot = pilot
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let rollout: RolloutAppKitIntent
        do {
            rollout = try RolloutAppKitIntent(envelope: envelope)
        } catch {
            return .reject("app-kit の版を広げる意図の形が違う（\(error.detail)）")
        }
        guard admin != nil else { return .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）") }
        guard let file = try await context.readable(AppKitFile.self, at: StatePath.appKit) else {
            return .reject("司令塔がまだ app-kit の版を読んでいない。少し待ってから押し直す")
        }
        let version = rollout.release.version
        guard let release = file.release(version) else { return .reject("app-kit に版 \(version) が見つからない") }
        guard release.ref == rollout.release.ref else { return .reject("app-kit \(version) のコミットが、見たときと違う。見直して押し直す") }
        if let current = file.rollout {
            if current.version != version, [.running, .failed].contains(current.state) {
                return .reject("app-kit \(current.version) を広げている途中。やめてから \(version) を広げる")
            }
            if current.version == version, current.state == .running { return .accept }
        }
        let now = context.timestamp
        let pilot = pilot
        try await context.updateAppKit(message: "app-kit \(version) を広げ始める") { file in
            let kept = file.rollout.map { $0.version == version ? Self.kept($0.targets) : [] } ?? []
            file.rollout = AppKitFile.Rollout(
                version: version, ref: release.ref, origin: rollout.intent, pilot: pilot, targets: kept, startedAt: now, updatedAt: now
            )
            return true
        }
        return .accept
    }

    /// やり直すときに引き継ぐ相手。PR が開いているもの（止めたものを含む）だけを、追い直すために残す
    static func kept(_ targets: [AppKitFile.Target]) -> [AppKitFile.Target] {
        targets.compactMap { target in
            guard target.pullRequest != nil, target.head != nil, [.open, .failed].contains(target.state) else { return nil }
            var kept = target
            kept.state = .open
            kept.problem = nil
            return kept
        }
    }
}

/// app-kit の版を広げるのをやめる意図（`stopAppKitRollout`）を受け付け、その版で開いている PR を管理用のトークンで閉じる。
/// マージ済みのものは戻さない（戻すときは前の版を広げる）
public struct StopAppKitRolloutHandler: IntentHandler {
    public var admin: AdminGitHub?

    public init(admin: AdminGitHub?) {
        self.admin = admin
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let stop: StopAppKitRolloutIntent
        do {
            stop = try StopAppKitRolloutIntent(envelope: envelope)
        } catch {
            return .reject("app-kit の版を広げるのをやめる意図の形が違う（\(error.detail)）")
        }
        guard let rollout = try await context.readable(AppKitFile.self, at: StatePath.appKit)?.rollout,
              rollout.version == stop.release.version, rollout.ref == stop.release.ref else {
            return .reject("app-kit \(stop.release.version) は広げていない")
        }
        switch rollout.state {
        case .stopped: return .accept
        case .finished: return .reject("app-kit \(rollout.version) はもう広げ終わっている。戻すときは前の版を広げる")
        case .running, .failed: break
        }
        guard let admin else { return .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）") }
        let (targets, problems) = await closing(rollout.targets, admin: admin, in: context)
        let now = context.timestamp
        try await context.updateAppKit(message: "app-kit \(rollout.version) を広げるのをやめた") { file in
            guard var current = file.rollout, current.version == rollout.version, current.ref == rollout.ref else { return false }
            current.targets = current.targets.map { target in targets.first { $0.repo == target.repo } ?? target }
            current.state = .stopped
            current.problem = nil
            current.updatedAt = now
            file.rollout = current
            return true
        }
        guard problems.isEmpty else { return .reject("やめたが、" + problems.joined(separator: "・") + "。GitHub で閉じる") }
        return .accept
    }

    /// 開いている PR を閉じ、閉じた相手を `stopped` にする。閉じられなかったもののわけも返す
    private func closing(
        _ targets: [AppKitFile.Target],
        admin: AdminGitHub,
        in context: CommanderContext
    ) async -> (targets: [AppKitFile.Target], problems: [String]) {
        var targets = targets
        var problems: [String] = []
        for index in targets.indices where [.open, .failed].contains(targets[index].state) {
            guard let number = targets[index].pullRequest else { continue }
            if let problem = await close(number, in: targets[index].repo, admin: admin, now: context.now()) {
                problems.append("\(targets[index].repo) の PR #\(number) を閉じられない（\(problem)）")
                continue
            }
            targets[index].state = .stopped
            targets[index].problem = nil
            targets[index].updatedAt = context.timestamp
        }
        return (targets, problems)
    }

    /// PR を閉じる。閉じられなければわけ（もう閉じている・マージ済みなら閉じたものとする）
    private func close(_ number: Int, in repo: RepositoryFullName, admin: AdminGitHub, now: Date) async -> String? {
        let github: GitHubPullRequests
        switch await admin.pullRequests(for: repo, now: now) {
        case let .success(made): github = made
        case let .failure(refusal): return refusal.description
        }
        do throws(PullRequestError) {
            let current = try await github.pullRequest(number: number)
            guard current.state == .open, !current.merged else { return nil }
            try await github.setState(number: number, to: .closed)
            return nil
        } catch {
            await admin.note(error, owner: repo.owner, now: now)
            return "\(error)"
        }
    }
}
