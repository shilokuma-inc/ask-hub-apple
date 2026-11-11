import Foundation

#if DEBUG
/// UI テストと撮影のために、起動引数で開く画面を決める（DEBUG だけ）。
///
/// 例: `-demoOpen deck:all`・`-demoOpen epic:rain-draft`・`-demoOpen section:macs`・`-demoOpen finished`（終わったものをすべて）、
/// スワイプの途中の色を撮るときは `-demoDrag 0:0.8`（選択肢の添字:進み具合）
enum DemoLaunch {
    static let openKey = "demoOpen"
    static let dragKey = "demoDrag"

    static func initialDestination(defaults: UserDefaults = .standard) -> (section: AppSection, route: AppRoute?)? {
        guard let value = defaults.string(forKey: openKey) else {
            return nil
        }
        return destination(from: value)
    }

    static func destination(from value: String) -> (section: AppSection, route: AppRoute?)? {
        let parts = value.split(separator: ":").map(String.init)
        guard let kind = parts.first else {
            return nil
        }
        let argument = parts.dropFirst().first ?? ""
        if let (section, makeRoute) = singleArgumentRoutes[kind] {
            return (section, makeRoute(argument))
        }
        switch kind {
        case "section":
            return AppSection(rawValue: argument).map { ($0, nil) }

        case "deck":
            return deck(parts).map { (.inbox, .deck($0)) }

        case "human":
            return parts.count == 3 ? (.inbox, .humanTask(epicID: parts[1], taskID: parts[2])) : nil

        case "finished":
            return (.progress, .finishedEpics)

        default:
            return nil
        }
    }

    /// 引数が 1 つの行き先（例: `epic:rain-draft`）
    private static let singleArgumentRoutes: [String: (AppSection, (String) -> AppRoute)] = [
        "epic": (.progress, AppRoute.epic),
        "goal": (.inbox, AppRoute.goal),
        "final": (.inbox, AppRoute.finalReview),
        "mac": (.macs, AppRoute.mac),
        "cleanup": (.macs, AppRoute.cleanup),
        "repository": (.repositories, AppRoute.repository)
    ]

    private static func deck(_ parts: [String]) -> DeckScope? {
        guard parts.count >= 2 else {
            return nil
        }
        if parts[1] == "all" {
            return .all
        }
        guard parts.count == 3 else {
            return nil
        }
        switch parts[1] {
        case "questions": return .questions(parts[2])
        case "decisions": return .decisions(parts[2])
        case "verifications": return .verifications(parts[2])
        default: return nil
        }
    }

    /// スワイプの途中の状態（撮影用）
    static func dragPreview(defaults: UserDefaults = .standard) -> SwipeDragState? {
        guard let value = defaults.string(forKey: dragKey) else {
            return nil
        }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[0]), let progress = Double(parts[1]) else {
            return nil
        }
        return SwipeDragState(candidate: index, progress: min(1, max(0, progress)))
    }
}
#endif
