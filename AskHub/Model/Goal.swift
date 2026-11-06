import Foundation

/// 着手前の確認で Claude が作るゴール。人が見て「開始」か「直してほしい」を選ぶ
struct Goal: Hashable {
    var version: Int
    /// 作るものの要約
    var summary: String
    /// 決まったこと（どの質問の回答から来たか）
    var decided: [Point]
    var notDoing: [String]
    /// 完了の条件
    var doneCriteria: [String]
    var tasks: [PlannedTask]
    /// 「直してほしい」を受けて Claude が直しているときの指示。直していなければ nil
    var revisionRequest: String?
    /// 最後のゴールの修正で反映しなかった指示と、その理由（決まったことを変える指示など。回答を変えて直してもらう）
    var notApplied: [String] = []

    struct Point: Hashable {
        var text: String
        var questionID: Question.ID?
    }

    struct PlannedTask: Hashable {
        var title: String
        /// 人がする作業が前提のタスク
        var humanTaskID: HumanTask.ID?
    }

    var isRevising: Bool { revisionRequest != nil }
}

/// AskHub だけではできない作業（App Store Connect の Web でしかできない設定など）
struct HumanTask: Identifiable, Hashable {
    let id: String
    var title: String
    var why: String
    var steps: [Step]
    var links: [Link]
    var deliverable: Deliverable
    /// この作業を前提にするタスク（ほかのタスクは進める）
    var blocksTaskIDs: [EpicTask.ID]
    var state: State

    struct Step: Hashable {
        var text: String
        /// 入れる値など、コピーできるもの
        var copyableValue: String?
    }

    struct Link: Hashable {
        var title: String
        var url: URL
    }

    enum Deliverable: Hashable {
        /// 「終わった」を押すだけ
        case none
        /// 設定ファイルなどを渡す
        case file(description: String)
        /// API キーなどの秘密の値。貼るとそのまま GitHub の Secrets に暗号化して入れ、AskHub にもリポジトリにも残さない
        case secret(name: String, repository: String)
    }

    enum State: Hashable {
        case todo
        /// 「終わった」を受けて、ワーカーが確かめている
        case verifying
        case done
        case verificationFailed(reason: String)
    }

    var needsHuman: Bool {
        switch state {
        case .todo, .verificationFailed:
            return true

        case .verifying, .done:
            return false
        }
    }
}
