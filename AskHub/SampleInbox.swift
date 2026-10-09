import AskHubKit
import Foundation

extension InboxModel {
    /// UI テストでサンプルデータを表示する起動引数
    static let sampleLaunchArgument = "-AskHubSampleInbox"

    /// アプリの起動時に使うモデル。デモモードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> InboxModel {
        if DemoMode.isEnabled {
            return sample()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(sampleLaunchArgument) {
            return sample()
        }
        #endif
        return InboxModel()
    }
}

extension IdeaRequestModel {
    /// アプリの起動時に使うモデル。デモモードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> IdeaRequestModel {
        if DemoMode.isEnabled {
            return sample()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            return sample()
        }
        #endif
        return IdeaRequestModel()
    }
}

extension MergeQueueModel {
    /// アプリの起動時に使うモデル。デモモードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> MergeQueueModel {
        if DemoMode.isEnabled {
            return sample()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            return sample()
        }
        #endif
        return MergeQueueModel()
    }
}

extension MergeQueueModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> MergeQueueModel {
        MergeQueueModel(tokenStore: InMemoryTokenStore(token: "sample")) { _ in SampleMergeQueue() }
    }
}

/// デモモード・Preview・UI テスト用。マージしたことにして GitHub には送らない
struct SampleMergeQueue: MergeQueueProviding {
    static let pullRequests = [
        EpicPullRequest(
            id: "PR_50",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 50,
            title: "【FEAT】epic/mvp を develop に取り込む",
            body: """
                ### 回答待ちの PR
                - なし

                ### 返答のない仮決め（既定値のまま確定）
                - #9 の 20 件

                ### 実機確認 Issue
                - #18 PAT の Keychain への保存
                - #27 ready-for-loop からのループの起動
                """,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/50")!,
            baseBranch: "develop",
            headBranch: "epic/mvp",
            headSHA: "0000000",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable
        ),
        EpicPullRequest(
            id: "PR_80",
            repository: "shilokuma-inc/notti-ios",
            number: 80,
            title: "【FEAT】epic/notification を develop に取り込む",
            body: "### 回答待ちの PR\n- #77",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/pull/80")!,
            baseBranch: "develop",
            headBranch: "epic/notification",
            headSHA: "0000001",
            author: "mrs1669",
            checks: .pending,
            mergeability: .mergeable
        ),
        EpicPullRequest(
            id: "PR_120",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 120,
            title: "【FEAT】epic/html-rendering を develop に取り込む",
            // HTML タグと Markdown が混ざった本文（表示の確認用）
            body: """
                <h3>回答待ちの PR</h3>
                <ul>
                <li>なし</li>
                </ul>
                <h3>返答のない仮決め（既定値のまま確定）</h3>
                <p>#161 の 6 件。<b>エンティティのデコード範囲</b>と <code>&lt;br&gt;</code> の変換を含む。詳細は <a href="https://github.com/shilokuma-inc/ask-hub-apple/issues/161">#161</a></p>

                ### 実機確認 Issue
                - なし

                ### 保留にしたタスク
                1. なし
                """,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/120")!,
            baseBranch: "develop",
            headBranch: "epic/html-rendering",
            headSHA: "0000002",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable
        )
    ]

    func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
        Self.pullRequests
    }

    func merge(_ pullRequest: EpicPullRequest) async throws {}
}

extension IdeaRequestModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample(sent: [SentRequest] = []) -> IdeaRequestModel {
        IdeaRequestModel(tokenStore: InMemoryTokenStore(token: "sample"), makeRequester: { _ in SampleIdeaRequester() }, sent: sent)
    }
}

extension SentRequest {
    /// Preview 用。送った依頼が複数あるときの一覧（新しい順）
    static let samples = [
        SentRequest(
            request: IdeaRequest(repository: "shilokuma-inc/notti-ios", summary: "通知の頻度を調整したい", body: "朝だけにしたい"),
            issue: CreatedIssue(number: 42, htmlURL: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/42")!)
        ),
        SentRequest(
            request: IdeaRequest(
                repository: "shilokuma-inc/ask-hub-apple",
                summary: "「依頼を送りました」の表示を、何をどこへ送ったか分かる形にしたい。続けて依頼したときも前の依頼を残したい",
                body: "送った時点のリポジトリと要約を出す"
            ),
            issue: CreatedIssue(number: 184, htmlURL: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/184")!)
        )
    ]
}

/// デモモード・Preview・UI テスト用。Issue を作ったことにして GitHub には送らない
struct SampleIdeaRequester: IdeaRequesting {
    func repositories(in orgs: [String]) async throws -> [RequestRepository] {
        [
            RequestRepository(fullName: "shilokuma-inc/ask-hub-apple", lastSeen: Date()),
            RequestRepository(fullName: "shilokuma-inc/notti-ios"),
            RequestRepository(fullName: "shilokuma-inc/claude-plugins"),
            RequestRepository(fullName: "shilokuma-inc/beat-tap-ios", lastSeen: Date()),
            RequestRepository(fullName: "shilokuma-inc/dotfiles")
        ]
    }

    func create(_ request: IdeaRequest) async throws -> CreatedIssue {
        CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
    }

    func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
        CreatedIssue(number: 43, htmlURL: URL(string: "https://github.com/\(repository)/issues/43")!)
    }
}

extension InboxModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeSource: { _ in SampleInboxSource() },
            makePoster: { _ in SampleAnswerPoster() },
            makeStarter: { _ in SampleLoopStarter() },
            // サンプルは GitHub に権限を問い合わせない
            makeTrust: { _ in TrustedAuthors.default }
        )
    }
}

/// デモモード・Preview・UI テスト用。ループを始める印を付けたことにして GitHub には送らない
struct SampleLoopStarter: LoopStarting {
    func markReadyForLoop(_ discussion: InboxSubject) async throws {}

    func markManualLoop(_ discussion: InboxSubject) async throws {}

    func assignManualLoop(_ discussion: InboxSubject, to login: String) async throws {}

    func assigneeCandidates(in repository: String) async throws -> [String] {
        ["mrs1669", "partner"]
    }

    func viewerLogin() async throws -> String {
        "mrs1669"
    }
}

/// デモモード・Preview・UI テスト用。投稿したことにして GitHub には送らない
struct SampleAnswerPoster: AnswerPosting {
    func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL {
        question.comment.url
    }
}

/// Preview と UI テスト用の固定の受信箱
struct SampleInboxSource: InboxSource {
    /// 選択肢のある Discussion の質問（Preview 用）
    static var sampleQuestion: InboxQuestion {
        let thread = sampleThreads(of: discussion)[0]
        return InboxQuestion(
            subject: discussion,
            comment: thread.comment,
            marker: QuestionMarker.parse(thread.comment.body) ?? QuestionMarker(id: "d12-q1")
        )
    }

    private static let now = Date()

    private static func subject(_ kind: InboxSubject.Kind, repository: String, number: Int, title: String) -> InboxSubject {
        let path = kind == .discussion ? "discussions" : "pull"
        return InboxSubject(
            kind: kind,
            nodeID: "\(repository)#\(number)",
            repository: repository,
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/\(path)/\(number)")!,
            author: TrustedAuthors.defaultLogins[0]
        )
    }

    private static func thread(_ subject: InboxSubject, id: String, minutesAgo: Double, body: String) -> QuestionThread {
        QuestionThread(
            comment: InboxComment(
                nodeID: "\(subject.nodeID)-\(id)",
                databaseID: nil,
                author: "mrs1669",
                body: body,
                url: subject.url,
                createdAt: now.addingTimeInterval(-minutesAgo * 60)
            ),
            replyAuthors: []
        )
    }

    private static let discussion = subject(.discussion, repository: "shilokuma-inc/notti-ios", number: 12, title: "通知の頻度を調整したい")
    private static let pullRequest = subject(
        .pullRequest,
        repository: "shilokuma-inc/ask-hub-apple",
        number: 34,
        title: "【FEAT】受信箱の一覧を追加する"
    )
    /// HTML タグと Markdown が混ざった質問を持つ Discussion（表示の確認用）
    private static let htmlDiscussion = subject(.discussion, repository: "shilokuma-inc/ask-hub-apple", number: 128, title: "HTMLタグの有効化")

    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        [Self.discussion, Self.pullRequest, Self.htmlDiscussion]
    }

    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        Self.sampleThreads(of: subject)
    }

    private static func sampleThreads(of subject: InboxSubject) -> [QuestionThread] {
        if subject == Self.discussion {
            return [
                Self.thread(subject, id: "q1", minutesAgo: 180, body: """
                    <!-- ask-hub:question id="d12-q1" options="24時間|1時間|送信1回分" -->
                    ### Q1. レート制限の単位
                    送信の上限をどの単位で数えますか？
                    """),
                Self.thread(subject, id: "q2", minutesAgo: 170, body: """
                    <!-- ask-hub:question id="d12-q2" -->
                    ### Q2. 通知の文言
                    通知に表示する文言の案があれば教えてください。
                    """)
            ]
        }
        if subject == Self.htmlDiscussion {
            return [
                Self.thread(subject, id: "q1", minutesAgo: 10, body: """
                    <!-- ask-hub:question id="d128-q1" options="よく使うタグ|すべてのタグ" -->
                    <h3>Q1. 解釈するタグの範囲</h3>
                    <p>質問の本文に <code>&lt;h3&gt;</code> のような HTML が混ざります。どこまで解釈しますか？</p>
                    <ul>
                    <li><b>よく使うタグ</b>: 見出し・太字・箇条書き・コード・リンク</li>
                    <li><i>すべてのタグ</i>: 表や <code>&lt;details&gt;</code> も再現する</li>
                    </ul>
                    参考: <a href="https://github.com/shilokuma-inc/ask-hub-apple/issues/127">#127</a>

                    ### 補足（Markdown）
                    - 見出しは `### Q1.` の書き方も混ざる
                    - どちらの書き方でも同じ見た目にそろえたい

                    ### 比較（表）
                    | 範囲 | 解釈するタグ | 手間 | 備考 |
                    | --- | --- | :-: | --- |
                    | **よく使うタグ** | 見出し・太字・箇条書き・`code`・リンク | 小 | 今の本文の大半 |
                    | すべてのタグ | 表・`<details>`・画像も含む | 大 | |
                    """)
            ]
        }
        return [
            Self.thread(subject, id: "1", minutesAgo: 25, body: """
                <!-- ask-hub:question id="pr34-1" options="App Store Connect で登録する|今回は見送る" -->
                ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
                新しい課金商品の Product ID を `jp.shilokuma.notti.pro` で登録してよいですか？
                """)
        ]
    }

    func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        [
            WaitingDiscussion(
                subject: Self.subject(.discussion, repository: "shilokuma-inc/ask-hub-apple", number: 15, title: "マージ待ちに件数のバッジを出したい"),
                lastSeen: Self.now.addingTimeInterval(-5 * 60),
                author: "mrs1669"
            ),
            WaitingDiscussion(
                subject: Self.subject(.discussion, repository: "shilokuma-inc/beat-tap-ios", number: 3, title: "練習モードを追加したい"),
                lastSeen: nil,
                author: "mrs1669"
            )
        ]
    }

    func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        [UsageLimitedRepository(repository: "shilokuma-inc/notti-ios", until: Self.now.addingTimeInterval(2 * 60 * 60))]
    }

    /// 自分（mrs1669）が担当の手動ループと、共同開発者（partner）が担当の手動ループ
    func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        [
            Self.manualLoop(repository: "shilokuma-inc/prime-pick-ios", number: 21, title: "難易度だけで選べるようにしたい", assignee: "mrs1669"),
            Self.manualLoop(repository: "shilokuma-inc/zankyo-apple", number: 8, title: "MVP を作る", assignee: "partner")
        ]
    }

    private static func manualLoop(repository: String, number: Int, title: String, assignee: String) -> ManualLoopRecord {
        let comment = ManualLoopAssignment.comment(assignee: assignee, repository: repository, discussionNumber: number)
        return ManualLoopRecord(
            subject: subject(.discussion, repository: repository, number: number, title: title),
            comments: [ManualLoopComment(author: "mrs1669", body: comment)]
        )
    }

    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        Self.issues
    }

    /// 実機確認には、目印（`ask-hub:verify`）のあるものと無いものの両方を入れる
    private static let issues = [
        InboxIssue(
            id: "I_9",
            kind: .decisionLog,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 9,
            title: "【CHORE】epic/mvp の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/9")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-3 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-10 * 60),
            body: """
                チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。返答のないものは既定値のまま確定する。

                - [x] #12 一覧の並び順 → 採用: 更新の新しい順（別案: 作成の古い順）
                - [ ] #14 自動更新の間隔 → 採用: 5 分（別案: 1 分 / 15 分）
                """
        ),
        InboxIssue(
            id: "I_18",
            kind: .needsVerify,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 18,
            title: "【CHORE】実機確認: PAT の Keychain への保存と macOS の設定画面の見た目",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-5 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-50 * 60),
            body: """
                \(VerifyMarker(pullRequest: 17, epic: "epic/mvp").marker)
                元の PR: #17

                ## 確認手順
                1. macOS 版の設定画面で PAT を入力して保存する
                2. アプリを終了して開き直す

                ## 期待する結果
                - PAT が残っていて、受信箱を取得できる
                - 設定画面の入力欄とボタンが重ならない
                """
        ),
        // 更新の新しい順では実機確認より後ろに来る判断ログ（セクションに分けたときの並びの確認用）
        InboxIssue(
            id: "I_77",
            kind: .decisionLog,
            repository: "shilokuma-inc/notti-ios",
            number: 77,
            title: "【CHORE】epic/notification の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/77")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-9 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-70 * 60),
            body: """
                チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。返答のないものは既定値のまま確定する。

                - [ ] #80 通知の既定の時刻 → 採用: 21 時（別案: 20 時 / 22 時）
                """
        ),
        // 目印（`ask-hub:verify`）が決まる前に起票された実機確認。本文の「元の PR」は自由文なので読まない
        InboxIssue(
            id: "I_52",
            kind: .needsVerify,
            repository: "shilokuma-inc/notti-ios",
            number: 52,
            title: "【CHORE】実機確認: 通知の許可ダイアログと届いた通知の表示",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/52")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-16 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-3 * 60 * 60),
            body: """
                元の PR: #41

                ## 確認手順
                1. 実機でアプリを初めて開き、通知を許可する
                2. 通知の時刻まで待つ

                ## 期待する結果
                - 設定した時刻に通知が届き、タップするとアプリが開く
                """
        )
    ]
}
