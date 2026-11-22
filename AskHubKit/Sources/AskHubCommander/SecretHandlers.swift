import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// リポジトリの Secrets の公開鍵を読ませる（`readSecretsKey`）を受け付け、管理用のトークンで読んで `repo.json` の `secretsKey` に書く。
/// クライアントは、この公開鍵で人がする作業の `secret` の値を暗号化する（クライアントのトークンは状態リポジトリしか読めないため）
public struct ReadSecretsKeyHandler: IntentHandler {
    public var admin: AdminGitHub?

    public init(admin: AdminGitHub?) {
        self.admin = admin
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let read: ReadSecretsKeyIntent
        do {
            read = try ReadSecretsKeyIntent(envelope: envelope)
        } catch {
            return .reject("公開鍵を読む意図の形が違う（\(error.detail)）")
        }
        guard let file = try await context.read(RepositoryFile.self, at: StatePath.repository(read.repo)) else {
            return .reject("\(read.repo) は対象のリポジトリに加えていない")
        }
        guard !file.isRemoved else { return .reject("\(read.repo) は対象から外した") }
        let handover = SecretHandover(admin: admin)
        switch await handover.readKey(for: read.repo, in: context) {
        case let .failure(refusal): return .reject(refusal.reason)
        case let .success(key): try await handover.record(key, for: read.repo, in: context)
        }
        return .accept
    }
}

/// Secrets の公開鍵を読み、暗号文を GitHub に入れる（管理用のトークンで）
struct SecretHandover {
    var admin: AdminGitHub?

    /// 暗号文を Secrets の `name` に入れる。入れられなければ断る理由。暗号化した鍵が今の公開鍵と違えば、新しい鍵を `repo.json` に書いて断る
    /// （クライアントが新しい鍵で入れ直す）
    func put(
        _ secret: EncryptedSecret,
        name: String,
        repo: RepositoryFullName,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        let github: GitHubPullRequests
        switch await self.github(for: repo, in: context) {
        case let .success(made): github = made
        case let .failure(refusal): return refusal.reason
        }
        let current: (keyId: String, key: String)
        do throws(PullRequestError) {
            current = try await github.secretsPublicKey()
            if current.keyId == secret.keyId {
                try await github.putSecret(name: name, encryptedValue: secret.encryptedValue, keyId: secret.keyId)
                return nil
            }
        } catch {
            await admin?.note(error, owner: repo.owner, now: context.now())
            return RepositorySetupRunner.reason("Secrets の \(name) に入れられない", error)
        }
        try await record(SecretsPublicKey(keyId: current.keyId, key: current.key, readAt: context.timestamp), for: repo, in: context)
        return "GitHub の Secrets の公開鍵が変わっていた。新しい鍵を読んだので、値を入れ直して送る"
    }

    /// 今の公開鍵を読む。読めなければ断る理由
    func readKey(for repo: RepositoryFullName, in context: CommanderContext) async -> Result<SecretsPublicKey, HandoverRefusal> {
        let github: GitHubPullRequests
        switch await self.github(for: repo, in: context) {
        case let .success(made): github = made
        case let .failure(refusal): return .failure(refusal)
        }
        do throws(PullRequestError) {
            let key = try await github.secretsPublicKey()
            return .success(SecretsPublicKey(keyId: key.keyId, key: key.key, readAt: context.timestamp))
        } catch {
            await admin?.note(error, owner: repo.owner, now: context.now())
            return .failure(HandoverRefusal(reason: RepositorySetupRunner.reason("Secrets の公開鍵を読めない", error)))
        }
    }

    /// 公開鍵を `repo.json` に書く（同じ鍵なら書かない）
    func record(_ key: SecretsPublicKey, for repo: RepositoryFullName, in context: CommanderContext) async throws(CommanderError) {
        do {
            try await context.files.update(RepositoryFile.self, at: StatePath.repository(repo), message: "\(repo) の Secrets の公開鍵を書く") {
                guard $0.secretsKey?.keyId != key.keyId || $0.secretsKey?.key != key.key else { return false }
                $0.secretsKey = key
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    private func github(for repo: RepositoryFullName, in context: CommanderContext) async -> Result<GitHubPullRequests, HandoverRefusal> {
        guard let admin else { return .failure(HandoverRefusal(reason: "この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）")) }
        switch await admin.pullRequests(for: repo, now: context.now()) {
        case let .success(github): return .success(github)
        case let .failure(refusal): return .failure(HandoverRefusal(reason: refusal.description))
        }
    }
}

/// Secrets の操作を断るわけ（クライアントに出す。値・トークンは含めない）
struct HandoverRefusal: Error {
    var reason: String
}
