import Foundation

/// 最終 PR（`epic-final`）の CI の失敗をオーケストレーターが直させた記録。オーケストレーターのコメントの先頭
/// （`FinalPullRequestMarker.orchestrator` の次の行）に置く。
///
/// ```html
/// <!-- ask-hub:orchestrator -->
/// <!-- ask-hub:ci-fix action="attempt" sha="<CI が失敗した head>" -->
/// ```
///
/// 直させる前に `attempt` を書くので、オーケストレーターを再起動しても同じ head では試し直さない。
/// 利用上限などで試せなかったときは `cancel` で取り消し、上限まで試してあきらめたら `gave-up` を書く。
/// 詳細は `docs/protocol.md` の「最終 PR の CI の修正の記録」を参照
public struct CIFixMarker: Sendable, Equatable, Hashable {
    public enum Action: String, Sendable, Equatable, Hashable, CaseIterable {
        /// この head で 1 回直させた（始める前に書く）
        case attempt
        /// 同じ head の `attempt` を取り消す（試したことにしない）
        case cancel
        /// 自動の修正をやめた（この PR では、もう直させない）
        case gaveUp = "gave-up"
    }

    static let keyword = "ask-hub:ci-fix"

    public var action: Action
    /// 対象の head のコミットの SHA（小文字にそろえる）
    public var sha: String

    public init(action: Action, sha: String) {
        self.action = action
        self.sha = sha.lowercased()
    }

    /// コメントに置く目印。`sha` が目印に書けない値なら `nil`
    public var htmlComment: String? {
        guard MarkerComment.isValidValue(sha) else {
            return nil
        }
        return "\(MarkerComment.open) \(Self.keyword) action=\"\(action.rawValue)\" sha=\"\(sha)\" \(MarkerComment.close)"
    }

    /// コメントの本文の先頭（`FinalPullRequestMarker.orchestrator` があればその次）の目印を読む。無ければ `nil`
    public static func parse(_ body: String) -> Self? {
        var rest = body.drop { $0.isWhitespace || $0.isNewline }
        if rest.hasPrefix(FinalPullRequestMarker.orchestrator) {
            rest = rest.dropFirst(FinalPullRequestMarker.orchestrator.count)
        }
        guard let attributes = MarkerComment.attributes(String(rest), keyword: keyword),
              let action = attributes["action"].flatMap(Action.init(rawValue:)),
              let sha = attributes["sha"], MarkerComment.isValidValue(sha) else {
            return nil
        }
        return Self(action: action, sha: sha)
    }
}

/// 最終 PR の CI の修正の記録を、目印（古い順）からまとめたもの
public struct CIFixRecord: Sendable, Equatable, Hashable {
    /// 直させた head（取り消したものを除く。古い順）
    public var attemptedSHAs: [String]
    /// 自動の修正をやめた
    public var gaveUp: Bool

    public init(attemptedSHAs: [String] = [], gaveUp: Bool = false) {
        self.attemptedSHAs = attemptedSHAs.map { $0.lowercased() }
        self.gaveUp = gaveUp
    }

    /// 目印（古い順）から記録をまとめる
    public init(markers: [CIFixMarker]) {
        var attempted: [String] = []
        var gaveUp = false
        for marker in markers {
            switch marker.action {
            case .attempt where !attempted.contains(marker.sha):
                attempted.append(marker.sha)

            case .attempt:
                break

            case .cancel:
                attempted.removeAll { $0 == marker.sha }

            case .gaveUp:
                gaveUp = true
            }
        }
        self.init(attemptedSHAs: attempted, gaveUp: gaveUp)
    }

    /// その head で直させたか
    public func attempted(_ sha: String) -> Bool {
        attemptedSHAs.contains(sha.lowercased())
    }
}
