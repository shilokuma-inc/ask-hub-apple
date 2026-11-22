import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// テンプレートから新しいアプリのリポジトリを作る（`createRepository`）を受け付け、管理用のトークンで作る
/// （`docs/renewal/operations.md` の「テンプレートからの新規作成」）。
///
/// 1. 作るリポジトリの持ち主の管理用のトークンで、決まったテンプレートから作る（同じテンプレートから同じ公開範囲で作ってあれば、続きから）
/// 2. 保護の無いうちに、アプリ名・Bundle ID を書き換えたコミットを develop に入れる（テンプレートの `scripts/rename.sh` と同じ中身。2026-11-22 にユーザーが決めた）
/// 3. 対象に加え（`repo.json`）、テンプレートから決まるビルドの設定を入れ、加えるときの GitHub 側の準備（`RepositorySetupStep`）を流す
///
/// 途中で止まったら理由を付けて断る。押し直すと、作ってあるものは作り直さずに続きから進める
public struct CreateRepositoryHandler: IntentHandler {
    public var admin: AdminGitHub?
    /// テンプレートから作り終わる（ブランチが出る）のを待つ間隔と回数
    var wait: Duration
    var attempts: Int
    var sleeper: any Sleeper

    public init(admin: AdminGitHub?, wait: Duration = .seconds(3), attempts: Int = 10, sleeper: any Sleeper = TaskSleeper()) {
        self.admin = admin
        self.wait = wait
        self.attempts = attempts
        self.sleeper = sleeper
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let create: CreateRepositoryIntent
        do {
            create = try CreateRepositoryIntent(envelope: envelope)
        } catch {
            return .reject("作る意図の形が違う（\(error.detail)）")
        }
        let path = StatePath.repository(create.repo)
        let existing = try await context.read(RepositoryFile.self, at: path)
        if let existing {
            // 前に作った（やり直し）なら続きから。対象に加えただけのリポジトリ・別の中身で作ったものは、作り直さない
            guard let created = existing.created else { return .reject("\(create.repo) はもう対象のリポジトリにある（テンプレートから作ったものでない）") }
            guard created.template == create.template, created.appName == create.appName, created.bundleId == create.bundleId,
                  created.visibility == create.visibility else {
                return .reject("\(create.repo) は前に別の中身（\(created.template.title)・\(created.appName)）で作った。別の名前で作り直す")
            }
            if created.renameCommit != nil, existing.build != nil { return .accept }
        }
        guard let admin else { return .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）") }
        let github: GitHubPullRequests
        switch await admin.pullRequests(for: create.repo, now: context.now()) {
        case let .success(made): github = made
        case let .failure(refusal): return .reject(refusal.description)
        }
        let renameCommit: String?
        do throws(RepositoryCreationError) {
            renameCommit = try await RepositoryCreationRunner(github: github, wait: wait, attempts: attempts, sleeper: sleeper).run(create)
        } catch {
            if case let .github(_, failure) = error { await admin.note(failure, owner: create.repo.owner, now: context.now()) }
            return .reject(error.description)
        }
        try await record(create, renameCommit: renameCommit, existing: existing, in: context)
        // 作ったリポジトリにも、対象に加えるときと同じ準備を流す（準備が止まっても、作ったのは受け付ける）
        try await RepositorySetupStep(admin: admin).run(for: create.repo, in: context)
        return .accept
    }

    /// `repo.json` を作る（やり直しなら、作った記録とビルドの設定を足す）。ビルドの設定は、人が入れたものがあれば変えない
    private func record(
        _ create: CreateRepositoryIntent,
        renameCommit: String?,
        existing: RepositoryFile?,
        in context: CommanderContext
    ) async throws(CommanderError) {
        let path = StatePath.repository(create.repo)
        let previous = existing?.created
        let creation = RepositoryFile.Creation(
            template: create.template,
            appName: create.appName,
            bundleId: create.bundleId,
            visibility: create.visibility,
            renameCommit: renameCommit ?? previous?.renameCommit,
            intent: previous?.intent ?? create.intent,
            at: previous?.at ?? context.timestamp
        )
        let build = try? create.template.build(appName: create.appName)
        do {
            if existing == nil {
                // 同時に回す epic は、対象に加えるときと同じく 1 本
                var file = RepositoryFile(repo: create.repo, platform: .apple, build: build, addedAt: context.timestamp)
                file.created = creation
                try await context.files.create(file, at: path, message: "\(create.repo) をテンプレートから作り、対象に加える")
            } else {
                try await context.files.update(RepositoryFile.self, at: path, message: "\(create.repo) をテンプレートから作った記録を書く") {
                    let before = $0
                    $0.created = creation
                    if $0.build == nil { $0.build = build }
                    $0.removedAt = nil
                    return $0 != before
                }
            }
        } catch {
            throw .files(error)
        }
    }
}

/// テンプレートから作り、名前を書き換えるまで。書き換えたコミットを返す（前に書き換えてあれば nil）
struct RepositoryCreationRunner {
    var github: GitHubPullRequests
    var wait: Duration
    var attempts: Int
    var sleeper: any Sleeper

    func run(_ create: CreateRepositoryIntent) async throws(RepositoryCreationError) -> String? {
        let template = create.template.repository
        let isPrivate = create.visibility == .private
        let existing = try await step("作る前に同じ名前のリポジトリを確かめられない") { () throws(PullRequestError) in
            try await github.existingRepository()
        }
        if let existing {
            guard existing.template?.lowercased() == template.rawValue.lowercased() else {
                throw .alreadyExists("\(create.repo) は既にある（\(template) から作ったものでない）。別の名前で作る")
            }
            guard existing.isPrivate == isPrivate else {
                let actual = existing.isPrivate ? "private" : "public"
                throw .alreadyExists("\(create.repo) は既に \(actual) で作ってある（意図は \(create.visibility.rawValue)）。GitHub で公開範囲を確かめてから作り直す")
            }
        } else {
            try await step("\(template) から \(create.repo) を作れない") { () throws(PullRequestError) in
                try await github.generate(from: template, isPrivate: isPrivate)
            }
        }
        let branch = existing?.defaultBranch ?? RepositoryFile.Build.defaultBaseBranch
        let head = try await branchHead(branch)
        let files = try await step("作ったリポジトリのファイルを読めない") { () throws(PullRequestError) in
            try await github.files(at: head)
        }
        guard let script = files.first(where: { $0.path == TemplateRename.scriptPath }) else {
            throw .template("テンプレートに \(TemplateRename.scriptPath) が無いので、名前を書き換えられない")
        }
        let shas = [script.sha] + files.filter(TemplateRename.needsText).map(\.sha)
        let texts = try await step("作ったリポジトリのファイルの中身を読めない") { () throws(PullRequestError) in
            try await github.blobTexts(shas)
        }
        guard let old = texts[script.sha].flatMap({ $0 }).flatMap(TemplateRename.oldNames) else {
            throw .template("\(TemplateRename.scriptPath) から元の名前（OLD_NAME・OLD_REPO）を読めない")
        }
        let names = TemplateRename.Names(appName: create.appName, repo: create.repo.rawValue, bundleId: create.bundleId)
        guard let plan = TemplateRename.plan(files: files, texts: texts, old: old, new: names) else { return nil }
        let message = "[chore] テンプレートから \(create.appName) を作る（アプリ名と Bundle ID を書き換える）"
        return try await step("名前を書き換えたコミットを \(branch) に入れられない") { () throws(PullRequestError) in
            try await github.commitFiles(plan, parent: head, branch: branch, message: message)
        }
    }

    /// テンプレートから作り終わって、ブランチが出るまで待つ
    private func branchHead(_ branch: String) async throws(RepositoryCreationError) -> String {
        for attempt in 0..<attempts {
            let head = try await step("作ったリポジトリの \(branch) を読めない") { () throws(PullRequestError) in
                try await github.branchHead(branch)
            }
            if let head { return head }
            if attempt + 1 < attempts {
                do {
                    try await sleeper.sleep(for: wait)
                } catch {
                    throw .github("待っている間に止められた", .cancelled)
                }
            }
        }
        throw .template("GitHub がまだ作っている途中（\(branch) が出ない）。少し待ってから押し直す")
    }

    private func step<Value>(
        _ what: String,
        _ body: () async throws(PullRequestError) -> Value
    ) async throws(RepositoryCreationError) -> Value {
        do {
            return try await body()
        } catch {
            throw .github(what, error)
        }
    }
}

/// テンプレートから作れなかった理由（クライアントに出す。トークンの値は含めない）
enum RepositoryCreationError: Error, CustomStringConvertible {
    case alreadyExists(String)
    case template(String)
    case github(String, PullRequestError)

    var description: String {
        switch self {
        case let .alreadyExists(message), let .template(message): message
        case let .github(what, .notFound):
            "\(what)（見つからない。管理用のトークンの Repository access を、その持ち主の All repositories にしてあるかを確かめる）"
        case let .github(what, .rateLimited(wait)): "\(what)（GitHub の上限。\(wait.components.seconds) 秒ほど待ってから押し直す）"
        case let .github(what, .rejected(message)): "\(what)（GitHub が断った: \(message ?? "")）"
        case let .github(what, error): RepositorySetupRunner.reason(what, error)
        }
    }
}
