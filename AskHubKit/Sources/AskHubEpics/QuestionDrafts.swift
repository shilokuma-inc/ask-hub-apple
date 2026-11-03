import AskHubProtocol
import Foundation

/// 質問を作る Claude が返す 1 つの質問の案（質問づくり・着手前の確認の追加の質問）
public struct QuestionDraft: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// なぜ決める必要があるか
    public var why: String
    public var options: [QuestionsFile.Option]
    public var recommended: String
    /// 推奨の理由
    public var reason: String
    /// 答えを前提にする質問の id
    public var dependsOn: [String]

    public init(
        id: String,
        title: String,
        why: String,
        options: [QuestionsFile.Option],
        recommended: String,
        reason: String,
        dependsOn: [String] = []
    ) {
        self.id = id
        self.title = title
        self.why = why
        self.options = options
        self.recommended = recommended
        self.reason = reason
        self.dependsOn = dependsOn
    }
}

/// 説明・見直しの Claude が返す、質問の書き直しの案。id・依存先・何回目の質問づくりかは変えない
public struct QuestionRewrite: Codable, Equatable, Sendable {
    public var title: String
    public var why: String
    public var options: [QuestionsFile.Option]
    public var recommended: String
    public var reason: String
    /// 書き直した理由（画面で「書き直した」と示すときに出す）
    public var change: String

    public init(title: String, why: String, options: [QuestionsFile.Option], recommended: String, reason: String, change: String) {
        self.title = title
        self.why = why
        self.options = options
        self.recommended = recommended
        self.reason = reason
        self.change = change
    }
}

/// 見直しを頼んだときの、質問と依存先の版と回答。
///
/// 見直しの結果を書く前に今の状態と比べ、頼んだ後に依存先の回答が変わっていたら、その結果を捨てる。
/// ジョブの `input` に入れて持ち回る
public struct RevisionBasis: Codable, Equatable, Sendable {
    public struct Dependency: Codable, Equatable, Sendable {
        public var id: String
        public var version: Int
        /// 受け付けた回答の人の意図。要らなくなった質問では nil
        public var answer: IntentReference?

        public init(id: String, version: Int, answer: IntentReference?) {
            self.id = id
            self.version = version
            self.answer = answer
        }
    }

    /// 見直す質問の版
    public var version: Int
    public var dependencies: [Dependency]

    public init(version: Int, dependencies: [Dependency]) {
        self.version = version
        self.dependencies = dependencies
    }
}
