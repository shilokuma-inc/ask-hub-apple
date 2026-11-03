import Foundation

/// タブ（iPhone）・サイドバー（Mac・iPad）の項目
enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case inbox
    case progress
    case macs
    case repositories

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "あなたの番"
        case .progress: "進行中"
        case .macs: "Mac"
        case .repositories: "リポジトリ"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .progress: "arrow.triangle.2.circlepath"
        case .macs: "laptopcomputer"
        case .repositories: "square.stack.3d.up"
        }
    }
}

/// 画面の行き先。あなたの番の項目や通知は、epic の段階ごとの画面への近道になる
enum AppRoute: Hashable {
    case epic(Epic.ID)
    /// 判断のカード（スワイプで選ぶ）
    case deck(DeckScope)
    case goal(Epic.ID)
    case humanTask(epicID: Epic.ID, taskID: HumanTask.ID)
    case finalReview(Epic.ID)
    case mac(Mac.ID)
    case cleanup(Mac.ID)
    case repository(TargetRepository.ID)
}

/// 判断のカードを、どの範囲で流すか
enum DeckScope: Hashable {
    /// アプリをまたいで、選択肢のある判断をすべて
    case all
    /// その epic の質問
    case questions(Epic.ID)
    /// その epic の最終 PR の判断のカード
    case decisions(Epic.ID)
    /// その epic の実機確認
    case verifications(Epic.ID)
}
