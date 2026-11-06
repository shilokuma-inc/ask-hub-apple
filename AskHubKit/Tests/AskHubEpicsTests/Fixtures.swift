@testable import AskHubEpics
import AskHubProtocol
import Foundation

enum Fixtures {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let now = Timestamp(rawValue: "2026-11-03T10:05:00Z")!

    static func epic(_ stage: EpicStage = .asking) -> EpicFile {
        EpicFile(
            id: epicID,
            repo: repo,
            title: "ランキング",
            discussion: 12,
            stage: stage,
            createdAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!,
            updatedAt: now
        )
    }

    /// n 番目の人の意図
    static func intent(_ number: Int) -> IntentReference {
        IntentReference(keyId: keyID, nonce: ULID(rawValue: "01JCN0NCE" + String(format: "%017d", number))!)
    }

    static func draft(_ id: String, dependsOn: [String] = []) -> QuestionDraft {
        QuestionDraft(
            id: id,
            title: "\(id) の題",
            why: "画面に関わるため",
            options: [.init(label: "日ごと", effect: "毎日入れ替わる"), .init(label: "週ごと", effect: "月曜に入れ替わる")],
            recommended: "日ごと",
            reason: "今の仕組みのままで作れる",
            dependsOn: dependsOn
        )
    }

    static func answer(
        _ question: String,
        version: Int = 1,
        _ mode: AnswerIntent.Mode = .answer,
        choice: String? = "日ごと",
        note: String = "",
        intent number: Int = 1
    ) -> AnswerIntent {
        AnswerIntent(
            repo: repo,
            epic: epicID,
            question: question,
            questionVersion: version,
            mode: mode,
            choice: mode == .answer ? choice : nil,
            note: note,
            intent: intent(number)
        )
    }

    static func rewrite(_ change: String = "選択肢を分けた") -> QuestionRewrite {
        QuestionRewrite(
            title: "書き直した題",
            why: "画面に関わるため",
            options: [.init(label: "毎日", effect: "…"), .init(label: "毎週", effect: "…"), .init(label: "毎月", effect: "…")],
            recommended: "毎日",
            reason: "今の仕組みのままで作れる",
            change: change
        )
    }
}

extension QuestionsFile {
    func question(_ id: String) -> Question? {
        questions.first { $0.id == id }
    }

    func states() -> [String: QuestionState] {
        Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.state) })
    }
}
