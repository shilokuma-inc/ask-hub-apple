import AskHubClient
import AskHubProtocol
import Foundation

/// 画面の人の意図（`HumanIntent`）を、状態リポジトリに送る形（`IntentDraft`）に変える。
///
/// 対象の版（質問・ゴール・着手前の確認の結果）は、最後に読んだ状態（`StateIndex`）から取る。人が見たものの版で送るので、
/// その後に対象が変わっていれば、司令塔が古い意図として断る
struct StateIntentMapper {
    let index: StateIndex

    /// 状態リポジトリに送れる意図か。段階 3 の操作（判断のカード・マージ・要対応・引き継ぎ・確認・片付け）は、まだ送れない
    static func supports(_ intent: HumanIntent) -> Bool {
        switch intent {
        case .answer, .requestExplanation, .reviseGoal, .start, .decideSplit, .request, .addRepository:
            true

        case .respondToDecision, .acceptAllDecisions, .merge, .resolveBlocker, .handOver, .pause, .resume, .discard,
             .completeHumanTask, .submitSecret, .verify, .cleanUp:
            false
        }
    }

    func draft(for intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case .answer, .requestExplanation:
            return try questionDraft(intent)

        case .reviseGoal, .start, .decideSplit:
            return try epicDraft(intent)

        case .request, .addRepository:
            return try repositoryDraft(intent)

        case .respondToDecision, .acceptAllDecisions, .merge, .resolveBlocker, .handOver, .pause, .resume, .discard,
             .completeHumanTask, .submitSecret, .verify, .cleanUp:
            throw Self.unsupported
        }
    }

    private static let unsupported = ClientServiceError(message: "この操作は、まだ状態リポジトリに送れません")

    private func questionDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .answer(epicID, questionID, optionID, note):
            return .answer(try question(questionID, in: epicID), choice: optionID, note: note)

        case let .requestExplanation(epicID, questionID, request):
            return .clarify(try question(questionID, in: epicID), note: request)

        default:
            throw Self.unsupported
        }
    }

    private func epicDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .reviseGoal(epicID, request):
            return .reviseGoal(try goal(of: epicID), instruction: request)

        case let .start(epicID, macID):
            guard let mac = MacName(rawValue: macID) else {
                throw ClientServiceError(message: "Mac の名前の形が違います")
            }
            return .startEpic(try goal(of: epicID), mac: mac)

        case let .decideSplit(epicID, choice):
            let epic = try epic(epicID)
            guard let version = epic.readinessVersion else {
                throw ClientServiceError(message: "着手前の確認の結果がまだありません")
            }
            return .decideSplit(EpicTarget(repo: epic.repo, epic: epic.id, version: version), choice: choice == .split ? .split : .proceed)

        default:
            throw Self.unsupported
        }
    }

    private func repositoryDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .request(repositoryID, summary, body):
            guard summary.count <= RequestIntent.maximumTitleLength, body.count <= RequestIntent.maximumBodyLength else {
                let limits = "要約は \(RequestIntent.maximumTitleLength) 文字、内容は \(RequestIntent.maximumBodyLength) 文字まで"
                throw ClientServiceError(message: "\(limits)です")
            }
            return .request(repo: try repository(repositoryID), title: summary, body: body)

        case .addRepository(let repositoryID):
            // 状態リポジトリにつないだときは候補の一覧が無いので、人が入れた owner/name を id にして送る
            guard let repo = index.repositories[repositoryID] ?? RepositoryFullName(rawValue: repositoryID) else {
                throw ClientServiceError(message: "owner/name の形で入れてください")
            }
            return .addRepository(repo)

        default:
            throw Self.unsupported
        }
    }

    private func epic(_ id: Epic.ID) throws(ClientServiceError) -> StateIndex.EpicEntry {
        guard let epic = index.epics[id] else {
            throw ClientServiceError(message: "この epic は、状態リポジトリにまだありません。取り直してから送ってください")
        }
        return epic
    }

    private func question(_ questionID: Question.ID, in epicID: Epic.ID) throws(ClientServiceError) -> QuestionTarget {
        let epic = try epic(epicID)
        guard let question = index.questions[epicID]?[questionID] else {
            throw ClientServiceError(message: "\(questionID) は、状態リポジトリにありません")
        }
        return QuestionTarget(repo: epic.repo, epic: epic.id, question: question.id, version: question.version)
    }

    /// 開始とゴールの修正の対象。確かめたゴールの版を付ける
    private func goal(of epicID: Epic.ID) throws(ClientServiceError) -> EpicTarget {
        let epic = try epic(epicID)
        guard let version = epic.goalVersion else {
            throw ClientServiceError(message: "ゴールがまだありません")
        }
        return EpicTarget(repo: epic.repo, epic: epic.id, version: version)
    }

    private func repository(_ id: TargetRepository.ID) throws(ClientServiceError) -> RepositoryFullName {
        guard let repo = index.repositories[id] else {
            throw ClientServiceError(message: "このリポジトリは、まだ対象に加わっていません")
        }
        return repo
    }
}
