import AskHubKit
import Foundation

extension InboxModel {
    /// UI テストでサンプルデータを表示する起動引数
    static let sampleLaunchArgument = "-AskHubSampleInbox"

    /// アプリの起動時に使うモデル。DEBUG ビルドでは起動引数でサンプルデータに切り替えられる
    static func launchDefault() -> InboxModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(sampleLaunchArgument) {
            return sample()
        }
        #endif
        return InboxModel()
    }
}

extension IdeaRequestModel {
    /// アプリの起動時に使うモデル。DEBUG ビルドでは起動引数でサンプルデータに切り替えられる
    static func launchDefault() -> IdeaRequestModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            return sample()
        }
        #endif
        return IdeaRequestModel()
    }
}

extension MergeQueueModel {
    /// アプリの起動時に使うモデル。DEBUG ビルドでは起動引数でサンプルデータに切り替えられる
    static func launchDefault() -> MergeQueueModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            return sample()
        }
        #endif
        return MergeQueueModel()
    }
}

#if DEBUG
extension MergeQueueModel {
    /// Preview と UI テスト用。GitHub には接続しない
    static func sample() -> MergeQueueModel {
        MergeQueueModel(tokenStore: InMemoryTokenStore(token: "sample")) { _ in SampleMergeQueue() }
    }
}

/// Preview と UI テスト用。マージしたことにして GitHub には送らない
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

    func epicPullRequests(org: String) async throws -> [EpicPullRequest] {
        Self.pullRequests
    }

    func merge(_ pullRequest: EpicPullRequest) async throws {}
}

extension IdeaRequestModel {
    /// Preview と UI テスト用。GitHub には接続しない
    static func sample() -> IdeaRequestModel {
        IdeaRequestModel(tokenStore: InMemoryTokenStore(token: "sample")) { _ in SampleIdeaRequester() }
    }
}

/// Preview と UI テスト用。Issue を作ったことにして GitHub には送らない
struct SampleIdeaRequester: IdeaRequesting {
    func repositories(in org: String) async throws -> [String] {
        ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios", "shilokuma-inc/beat-tap-ios"]
    }

    func create(_ request: IdeaRequest) async throws -> CreatedIssue {
        CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
    }
}

extension InboxModel {
    /// Preview と UI テスト用。GitHub には接続しない
    static func sample() -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeSource: { _ in SampleInboxSource() },
            makePoster: { _ in SampleAnswerPoster() },
            makeStarter: { _ in SampleLoopStarter() }
        )
    }
}

/// Preview と UI テスト用。ループを始める印を付けたことにして GitHub には送らない
struct SampleLoopStarter: LoopStarting {
    func markReadyForLoop(_ discussion: InboxSubject) async throws {}
}

/// Preview と UI テスト用。投稿したことにして GitHub には送らない
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
            url: URL(string: "https://github.com/\(repository)/\(path)/\(number)")!
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

    func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
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

    func waitingDiscussions(org: String) async throws -> [WaitingDiscussion] {
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

    func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
        [
            InboxIssue(
                id: "I_9",
                kind: .decisionLog,
                repository: "shilokuma-inc/ask-hub-apple",
                number: 9,
                title: "【CHORE】epic/mvp の仮決め一覧",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/9")!,
                author: "mrs1669",
                updatedAt: Self.now.addingTimeInterval(-10 * 60)
            ),
            InboxIssue(
                id: "I_18",
                kind: .needsVerify,
                repository: "shilokuma-inc/ask-hub-apple",
                number: 18,
                title: "【CHORE】実機確認: PAT の Keychain への保存と macOS の設定画面の見た目",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
                author: "mrs1669",
                updatedAt: Self.now.addingTimeInterval(-50 * 60)
            )
        ]
    }
}
#endif
