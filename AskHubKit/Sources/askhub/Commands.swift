import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
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
        let draft = try draft(command, arguments)
        let connection = try connection()
        let sent = try await IntentSender(store: connection.store, key: connection.key).send(draft)
        print("\(draft.kind) を送りました（intents/\(sent.keyId.rawValue)/\(sent.nonce.rawValue).json）。司令塔が次の周で処理します")
    }

    static func draft(_ command: String, _ arguments: CommandArguments) throws -> IntentDraft {
        switch command {
        case "add-repository":
            try arguments.only(["repo"])
            return .addRepository(try arguments.repository())
        case "request":
            try arguments.only(["repo", "title", "body"])
            return .request(repo: try arguments.repository(), title: try arguments.string("title"), body: arguments.values["body"] ?? "")
        case "answer", "clarify":
            return try answer(command, arguments)
        case "abandon":
            try arguments.only(["repo", "epic"])
            return .abandonEpic(repo: try arguments.repository(), epic: try arguments.epic())
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
