import AskHubKit
import Foundation

extension InboxModel {
    /// UI テストでサンプルデータを表示する起動引数
    static let sampleLaunchArgument = "-AskHubSampleInbox"

    /// アプリの起動時に使うモデル。デモモード・撮影モードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> InboxModel {
        if DemoMode.usesSampleData {
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
    /// アプリの起動時に使うモデル。デモモード・撮影モードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> IdeaRequestModel {
        if DemoMode.usesSampleData {
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
    /// アプリの起動時に使うモデル。デモモード・撮影モードならサンプルデータ。DEBUG ビルドでは起動引数でも切り替えられる
    static func launchDefault() -> MergeQueueModel {
        if DemoMode.usesSampleData {
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

extension IdeaRequestModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample(sent: [SentRequest] = []) -> IdeaRequestModel {
        IdeaRequestModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeRequester: { _ in SampleIdeaRequester() },
            makeProblemCommenter: { _ in SampleVerifyProblemCommenter() },
            sent: sent,
            release: .sample()
        )
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
            RequestRepository(fullName: "shilokuma-inc/dotfiles"),
            // 依頼先の Picker の owner ごとの区切り（Discussion #572）を見せるため、2 つ目の organization のリポジトリも出す
            RequestRepository(fullName: "shilokuma-labs/web-tools", lastSeen: Date()),
            RequestRepository(fullName: "shilokuma-labs/sandbox")
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
            makeCloser: { _ in SampleIssueCloser() },
            makeApprover: { _ in SampleDecisionApprover() },
            makeInstructionPoster: { _ in SampleDecisionInstructionPoster() },
            // サンプルは GitHub に権限を問い合わせない
            makeTrust: { _ in TrustedAuthors.default },
            makeCommentsFetcher: { _ in SampleDecisionLogComments() }
        )
    }
}

/// デモモード・Preview・UI テスト用。実機確認の Issue を閉じたことにして GitHub には送らない
struct SampleIssueCloser: IssueClosing {
    func closeAsVerified(_ issue: InboxIssue) async throws {}
}

/// デモモード・Preview・UI テスト用。渡された Issue の本文のチェックを付けたことにして GitHub には送らない
struct SampleDecisionApprover: DecisionApproving {
    func approve(_ text: String, in issue: InboxIssue) async throws -> DecisionApproval {
        switch DecisionLogCheck.check(text, in: issue.body) {
        case let .checked(body):
            .approved(body: body)

        case .alreadyChecked:
            .alreadyApproved(body: issue.body)

        case .notFound:
            .notFound(body: issue.body)
        }
    }
}

/// デモモード・Preview・UI テスト用。指示を投稿したことにして GitHub には送らない
struct SampleDecisionInstructionPoster: DecisionInstructionPosting {
    func post(_ instruction: DecisionInstruction, for item: DecisionLogItem, to issue: InboxIssue) async throws -> URL {
        guard instruction.body(for: item) != nil else {
            throw DecisionInstructionError.invalidInstruction
        }
        return URL(string: "\(issue.url.absoluteString)#issuecomment-1")!
    }
}

/// デモモード・Preview・UI テスト用。ループを始める印を付けたことにして GitHub には送らない
struct SampleLoopStarter: LoopStarting {
    func markReadyForLoop(_ discussion: InboxSubject) async throws {}

    func markManualLoop(_ discussion: InboxSubject) async throws {}

    func setLoopOptions(_ options: LoopOptions, on discussion: InboxSubject) async throws {}

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

    /// サンプルの日時の基準（`SampleInbox+Issues.swift` からも使う）
    static let now = Date()

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
                // 作成日時では、間に PR の ask と別の Discussion の質問が入る（一覧では Q1 に続けて並ぶ。Discussion #418 の Q1）
                Self.thread(subject, id: "q2", minutesAgo: 15, body: """
                    <!-- ask-hub:question id="d12-q2" -->
                    ### Q2. 通知の文言
                    通知に表示する文言の案があれば教えてください。
                    """)
            ]
        }
        if subject == Self.htmlDiscussion {
            return [
                Self.thread(subject, id: "q1", minutesAgo: 60, body: """
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
            Self.thread(subject, id: "1", minutesAgo: 120, body: """
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

    /// 自分（mrs1669）が担当の手動ループ 2 つと、共同開発者（partner）が担当の手動ループ
    func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        [
            Self.manualLoop(repository: "shilokuma-inc/prime-pick-ios", number: 21, title: "難易度だけで選べるようにしたい", assignee: "mrs1669"),
            Self.manualLoop(repository: "shilokuma-inc/zankyo-apple", number: 8, title: "MVP を作る", assignee: "partner"),
            // 全タスクを終えたが、最終 PR に指示が付いた（ステータスタブで再開を促す）
            Self.manualLoop(repository: "shilokuma-inc/pair-quiz-ios", number: 54, title: "ヒントを出せるようにしたい", assignee: "mrs1669")
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

    /// 目印（`ask-hub:verify`）のある実機確認の Issue（Preview 用）
    static var sampleVerifyIssue: InboxIssue {
        issues.first { $0.verifyMarker != nil } ?? issues[0]
    }

    /// 承認済み・変更済み・未確認・形式に合わない項目を含む仮決め一覧（Preview 用）
    static var sampleDecisionLog: InboxIssue {
        issues[0]
    }
}
