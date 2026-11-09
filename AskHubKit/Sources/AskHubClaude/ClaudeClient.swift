import AskHubCommands
import AskHubProtocol
import Foundation

/// 1 つのジョブで Claude に頼んだ結果（何回か直させたときは、その合計）
public struct ClaudeSession: Equatable, Sendable {
    /// 会話の id（`--resume` で続けられる）
    public var id: String?
    /// 指定して、実際に使われたモデル
    public var model: String
    /// 見積もりの費用（直させた分も含む会話全体。サブスクリプションでは実際には払わない。使用量の目安）
    public var estimatedCostUsd: Double?
    /// 呼び出した回数（最初の 1 回と、直させた回数）
    public var calls: Int

    /// 試行に書く記録
    public var attemptRecord: AttemptFile.Claude {
        AttemptFile.Claude(model: model, session: id, estimatedCostUsd: estimatedCostUsd)
    }
}

public enum ClaudeReply<Output: Sendable>: Sendable {
    case answered(Output, ClaudeSession)
    /// `session` は、途中まで呼べていればその記録
    case failed(AttemptFailure, ClaudeSession?)
}

/// Claude を呼び、決まった形の結果を受け取る（`docs/renewal/flows.md` の「質問づくり・説明・確かめを Claude に頼むとき」）。
///
/// 結果は `--json-schema` で形を決めて受け取り、受け取る型で読んでから `check` で確かめる。
/// 合わなければ、同じ会話を再開して合わない点を伝え、直させる（`maximumCorrections` 回まで）
public struct ClaudeClient: Sendable {
    public var setup: ClaudeSetup
    public var runner: any CommandRunning
    public var maximumCorrections: Int
    /// 利用上限の解除の時刻を読む時間帯
    public var timeZone: TimeZone

    public init(setup: ClaudeSetup, runner: any CommandRunning, maximumCorrections: Int = 2, timeZone: TimeZone = .current) {
        self.setup = setup
        self.runner = runner
        self.maximumCorrections = maximumCorrections
        self.timeZone = timeZone
    }

    /// `deadline` を渡すと、直させる呼び出しも含めて、その時刻までに打ち切る（1 回の上限は `request.timeout` のまま）
    public func ask<Output: Decodable & Sendable>(
        _ request: ClaudeRequest,
        as type: Output.Type = Output.self,
        now: @Sendable () -> Date = Date.init,
        deadline: Date? = nil,
        check: @Sendable (Output) -> [String] = { _ in [] }
    ) async -> ClaudeReply<Output> {
        var request = request
        let callTimeout = request.timeout
        var session: ClaudeSession?
        for correction in 0...maximumCorrections {
            if let deadline {
                guard let left = Self.remaining(until: deadline, now: now()) else { return .failed(Self.pastDeadline(deadline), session) }
                request.timeout = min(callTimeout, left)
            }
            let message: ClaudeResultMessage
            switch await call(request, now: now) {
            case let .failed(failure):
                return .failed(failure, session)
            case let .finished(value):
                message = value
            }
            // `--resume` した結果の費用（と modelUsage）は、会話全体の累計（claude 2.1.317 で確かめた）。足さずに、最後の値を使う
            session = ClaudeSession(
                id: message.sessionID ?? session?.id,
                model: request.model,
                estimatedCostUsd: message.totalCostUsd ?? session?.estimatedCostUsd,
                calls: (session?.calls ?? 0) + 1
            )
            guard message.models.contains(request.model) else {
                let used = message.models.joined(separator: "・")
                return .failed(.init(failureClass: .unexpected, message: "指定したモデル（\(request.model)）で動かなかった（実際: \(used)）"), session)
            }
            let problems: [String]
            switch Self.decode(Output.self, from: message) {
            case let .success(output):
                problems = check(output)
                if problems.isEmpty, let session { return .answered(output, session) }
            case let .failure(problem):
                problems = [problem.text]
            }
            guard correction < maximumCorrections, let id = message.sessionID else {
                let excerpt = Redaction.excerpt(of: problems.joined(separator: "\n"), secrets: [setup.oauthToken])
                let failure = AttemptFailure(failureClass: .unexpected, message: "Claude の結果が決まりに合わない（直させても直らなかった）", logExcerpt: excerpt)
                return .failed(failure, session)
            }
            request.resume = id
            request.prompt = Self.correctionPrompt(problems)
        }
        return .failed(.init(failureClass: .unexpected, message: "Claude の結果を受け取れなかった"), session)
    }

    /// `deadline` までの残り。過ぎていれば nil
    public static func remaining(until deadline: Date, now: Date) -> Duration? {
        let left = Duration.milliseconds(Int64((deadline.timeIntervalSince(now) * 1_000).rounded(.down)))
        return left > .zero ? left : nil
    }

    static func pastDeadline(_ deadline: Date) -> AttemptFailure {
        AttemptFailure(failureClass: .timeout, message: "時間の上限（\(Timestamp(deadline).rawValue)）を過ぎた")
    }

    private enum CallOutcome {
        case finished(ClaudeResultMessage)
        case failed(AttemptFailure)
    }

    /// 1 回呼ぶ。決まった形で終わらなかった呼び出しは、失敗の区分に分ける
    private func call(_ request: ClaudeRequest, now: () -> Date) async -> CallOutcome {
        let command: Command
        do {
            command = try ClaudeCommandLine.command(for: request, setup: setup)
        } catch {
            return .failed(.init(failureClass: .unexpected, message: "Claude への依頼を組み立てられない（\(error)）"))
        }
        let result: CommandResult
        do {
            result = try await runner.run(command)
        } catch {
            return .failed(.init(failureClass: .unexpected, message: "claude を起動できない（\(error.localizedDescription)）"))
        }
        let message = ClaudeResultMessage(standardOutput: result.standardOutput)
        // 結果の JSON と終了コードの両方が成功を示すときだけ、成功とする
        if let message, message.succeeded, result.succeeded {
            return .finished(message)
        }
        let classifier = ClaudeFailureClassifier(timeZone: timeZone, now: now(), secrets: [setup.oauthToken])
        return .failed(classifier.failure(for: result, message: message, timeout: request.timeout))
    }

    private struct DecodeProblem: Error {
        var text: String
    }

    private static func decode<Output: Decodable>(_ type: Output.Type, from message: ClaudeResultMessage) -> Result<Output, DecodeProblem> {
        guard let data = message.structuredOutput else { return .failure(DecodeProblem(text: "決まった形の結果（structured_output）が無い")) }
        do {
            return .success(try JSONDecoder().decode(Output.self, from: data))
        } catch {
            return .failure(DecodeProblem(text: "決まった形で読めない（\(error)）"))
        }
    }

    /// 合わない点を伝えて直させる依頼
    static func correctionPrompt(_ problems: [String]) -> String {
        """
        前の結果は、次の点で決まりに合いませんでした。直した結果を、同じ形でもう一度返してください。

        \(problems.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
