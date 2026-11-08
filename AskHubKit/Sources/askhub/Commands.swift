import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

extension AskHubMain {
    /// 設定を書き、GitHub のトークンを Keychain に置き、署名の鍵を作る（Secure Enclave があればそこに）
    static func setup(_ arguments: CommandArguments) throws {
        try arguments.only(["state-repo", "state-branch"])
        let repository = try arguments.repository("state-repo")
        let configuration = ClientConfiguration(stateRepository: repository, stateBranch: arguments.values["state-branch"])
        let secrets = secrets
        let existing = try secrets.read(.githubToken) != nil
        let token = readSecret("GitHub のトークン（状態リポジトリを読み書きできるもの）" + (existing ? "（今のままなら空で Enter）: " : ": "))
        if token.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
        } else {
            try secrets.write(Data(token.utf8), for: .githubToken)
        }
        let key = try DeviceSigningKey.loadOrCreate(in: secrets)
        try configuration.save()
        print("""
            設定を \(ClientConfiguration.url().path) に書きました。
            署名の鍵: \(key.keyID.rawValue)（\(key.storage.rawValue)）
            最初の鍵として登録するなら: askhub key register-first --account <GitHub のアカウント> --label <名前>
            """)
    }

    static func key(_ arguments: [String]) async throws {
        var rest = arguments
        let action = rest.isEmpty ? "show" : rest.removeFirst()
        let parsed = try CommandArguments(rest)
        let connection = try connection()
        let key = connection.key
        let writer = KeyLedgerWriter(store: connection.store, key: key)
        switch action {
        case "show":
            try parsed.only([])
            print("鍵: \(key.keyID.rawValue)（\(key.storage.rawValue)）\n公開鍵: \(Base64URL.encode(key.publicKeyDER))")
        case "register-first":
            try parsed.only(["account", "label"])
            let seq = try await writer.registerFirst(account: try parsed.string("account"), label: try parsed.string("label"))
            print("最初の鍵として登録しました（keys/\(seq).json）。司令塔の setup の --first-key に \(key.keyID.rawValue) を渡します")
        case "add":
            try parsed.only(["public-key", "account", "label"])
            guard let der = Base64URL.decode(try parsed.string("public-key")) else {
                throw CommandArguments.Failure(message: "--public-key の形が違う")
            }
            let seq = try await writer.add(publicKeyDER: der, account: try parsed.string("account"), label: try parsed.string("label"))
            print("鍵 \(IntentSignature.keyID(publicKeyDER: der).rawValue) を登録しました（keys/\(seq).json）")
        case "revoke":
            try parsed.only([], positional: true)
            guard parsed.positional.count == 1 else { throw CommandArguments.Failure(message: "取り消す鍵の id を 1 つだけ書く") }
            guard let target = parsed.positional.first.flatMap(KeyID.init(rawValue:)) else {
                throw CommandArguments.Failure(message: "取り消す鍵の id が要る")
            }
            let seq = try await writer.revoke(target)
            print("鍵 \(target.rawValue) を取り消しました（keys/\(seq).json）")
        default:
            throw CommandArguments.Failure(message: "key の後は show・register-first・add・revoke")
        }
    }

    /// 人の意図を作って送る
    static func send(_ command: String, _ arguments: CommandArguments) async throws {
        let (draft, attachments) = command == "human-task-done" ? try humanTaskDone(arguments) : (try draft(command, arguments), [])
        let connection = try connection()
        let sent = try await IntentSender(store: connection.store, key: connection.key).send(draft, attachments: attachments)
        print("\(draft.kind) を送りました（intents/\(sent.keyId.rawValue)/\(sent.nonce.rawValue).json）。司令塔が次の周で処理します")
    }

    static func draft(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        switch command {
        case "add-repository":
            try arguments.only(["repo"])
            return .addRepository(try arguments.repository())
        case "configure-repository":
            try arguments.only(["repo", "file"])
            return .configureRepository(try arguments.repository(), build: try build(at: try arguments.string("file")))
        case "request":
            try arguments.only(["repo", "title", "body"])
            return .request(repo: try arguments.repository(), title: try arguments.string("title"), body: arguments.values["body"] ?? "")
        case "answer", "clarify":
            return try answer(command, arguments)
        case "decide", "approve-merge", "instruct-final":
            return try finalDraft(command, arguments)
        case "abandon", "pause", "resume", "handover":
            return try epicControlDraft(command, arguments)
        case "retry", "give-up":
            try arguments.only(["repo", "epic", "job", "attempt"])
            guard let job = ULID(rawValue: try arguments.string("job")) else { throw CommandArguments.Failure(message: "--job の形が違う") }
            let (repo, epic, attempt) = (try arguments.repository(), try arguments.epic(), try arguments.integer("attempt"))
            let target = JobTarget(repo: repo, epic: epic, job: job, attempt: attempt)
            return command == "retry" ? .retry(target) : .giveUp(target)
        default:
            return try epicDraft(command, arguments)
        }
    }

    /// ビルドの設定の JSON（`repo.json` の `build` と同じ形）を読み、送る前に司令塔と同じ決まりで確かめる
    private static func build(at path: String) throws -> RepositoryFile.Build {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            throw CommandArguments.Failure(message: "--file を読めない（\(error.localizedDescription)）")
        }
        guard let value = try? JSONValue(parsing: data) else { throw CommandArguments.Failure(message: "--file の中身が JSON でない") }
        do {
            return try ConfigureRepositoryIntent.build(from: value)
        } catch {
            throw CommandArguments.Failure(message: "ビルドの設定の形が違う（\(error.detail)）")
        }
    }

    private static func answer(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        // 説明を求めるときは選択肢を書かない（書いても回答にはならないので、黙って捨てずに断る）
        let names: Set = ["repo", "epic", "question", "version", "note"]
        try arguments.only(command == "clarify" ? names : names.union(["choice"]))
        let question = QuestionTarget(
            repo: try arguments.repository(),
            epic: try arguments.epic(),
            question: try arguments.string("question"),
            version: try arguments.integer("version")
        )
        if command == "clarify" { return .clarify(question, note: try arguments.string("note")) }
        return .answer(question, choice: arguments.values["choice"], note: arguments.values["note"] ?? "")
    }

    /// 人がする作業を終えた。`--file` があれば、そのファイルを渡す（依頼の添付と同じ上限）
    private static func humanTaskDone(_ arguments: CommandArguments) throws -> (IntentDraft, [Data]) {
        try arguments.only(["repo", "epic", "task", "version", "file"])
        let target = HumanTaskTarget(
            repo: try arguments.repository(),
            epic: try arguments.epic(),
            task: try arguments.string("task"),
            goalVersion: try arguments.integer("version")
        )
        guard let path = arguments.values["file"] else { return (.humanTaskDone(target), []) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CommandArguments.Failure(message: "--file を読めない（\(error.localizedDescription)）")
        }
        guard (1...RequestIntent.maximumAttachmentBytes).contains(data.count) else {
            throw CommandArguments.Failure(message: "--file は 1 バイト以上、\(RequestIntent.maximumAttachmentBytes / 1024 / 1024) MB まで")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = RequestAttachment(number: 1, name: url.lastPathComponent, size: data.count, sha256: digest)
        return (.humanTaskDone(target, file: file), [data])
    }

    /// 最終 PR と判断のカードへの意図。どれも、見たときの最終 PR の head（40 桁の SHA）に結びつく
    private static func finalDraft(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        switch command {
        case "decide": try arguments.only(["repo", "epic", "head", "decision", "answer", "note"])
        case "approve-merge": try arguments.only(["repo", "epic", "head"])
        default: try arguments.only(["repo", "epic", "head", "instruction"])
        }
        let head = try arguments.string("head")
        guard AttemptFile.isCommitSHA(head) else { throw CommandArguments.Failure(message: "--head は最終 PR の head のコミット（40 桁の SHA）") }
        let (repo, epic) = (try arguments.repository(), try arguments.epic())
        switch command {
        case "decide":
            guard let answer = DecisionsFile.Choice(rawValue: try arguments.string("answer")) else {
                throw CommandArguments.Failure(message: "--answer は ok・alternative・fix")
            }
            let target = DecisionTarget(repo: repo, epic: epic, decision: try arguments.string("decision"), head: head)
            return .decision(target, answer: answer, note: arguments.values["note"] ?? "")
        case "approve-merge":
            return .approveMerge(FinalPullRequestTarget(repo: repo, epic: epic, head: head))
        default:
            let target = FinalPullRequestTarget(repo: repo, epic: epic, head: head)
            return .instructFinal(target, instruction: try arguments.string("instruction"))
        }
    }

    /// 版を持たずに epic を対象にする意図（取り下げ・一時停止・再開・引き継ぎ）
    private static func epicControlDraft(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        try arguments.only(command == "handover" ? ["repo", "epic", "mac"] : ["repo", "epic"])
        let (repo, epic) = (try arguments.repository(), try arguments.epic())
        switch command {
        case "abandon":
            return .abandonEpic(repo: repo, epic: epic)
        case "pause":
            return .pauseEpic(repo: repo, epic: epic)
        case "resume":
            return .resumeEpic(repo: repo, epic: epic)
        default:
            guard let mac = MacName(rawValue: try arguments.string("mac")) else { throw CommandArguments.Failure(message: "--mac の形が違う") }
            return .handover(repo: repo, epic: epic, to: mac)
        }
    }

    private static func epicDraft(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        let target = EpicTarget(repo: try arguments.repository(), epic: try arguments.epic(), version: try arguments.integer("version"))
        switch command {
        case "start":
            try arguments.only(["repo", "epic", "version", "mac"])
            guard let mac = MacName(rawValue: try arguments.string("mac")) else { throw CommandArguments.Failure(message: "--mac の形が違う") }
            return .startEpic(target, mac: mac)
        case "revise-goal":
            try arguments.only(["repo", "epic", "version", "instruction"])
            return .reviseGoal(target, instruction: try arguments.string("instruction"))
        default:
            try arguments.only(["repo", "epic", "version", "choice"])
            guard let choice = DecideSplitIntent.Choice(rawValue: try arguments.string("choice")) else {
                throw CommandArguments.Failure(message: "--choice は split か proceed")
            }
            return .decideSplit(target, choice: choice)
        }
    }
}
