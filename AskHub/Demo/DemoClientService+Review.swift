import Foundation

// MARK: - 人の意図を当てる（実装から最終 PR・運用まで）

extension DemoClientService {
    func applyReviewIntent(_ intent: HumanIntent) {
        switch intent {
        case let .respondToDecision(epicID, decisionID, reply):
            respond(epicID: epicID, decisionID: decisionID, reply: reply)

        case .acceptAllDecisions(let epicID):
            acceptAllDecisions(epicID: epicID)

        case let .merge(epicID, headCommit):
            merge(epicID: epicID, headCommit: headCommit)

        case let .instructFinal(epicID, headCommit, instruction):
            instructFinal(epicID: epicID, headCommit: headCommit, instruction: instruction)

        case let .verify(epicID, itemID, reply):
            verify(epicID: epicID, itemID: itemID, reply: reply)

        default:
            break
        }
    }

    func applyOperationIntent(_ intent: HumanIntent) {
        switch intent {
        case let .resolveBlocker(epicID, action, instruction, _):
            resolveBlocker(epicID: epicID, action: action, instruction: instruction)

        case let .handOver(epicID, macID):
            handOver(epicID: epicID, macID: macID)

        case .pause(let epicID):
            pause(epicID: epicID)

        case .resume(let epicID):
            resume(epicID: epicID)

        case .discard(let epicID):
            state.epics.removeAll { $0.id == epicID }

        case let .completeHumanTask(epicID, taskID), let .submitSecret(epicID, taskID):
            completeHumanTask(epicID: epicID, taskID: taskID)

        case let .cleanUp(macID, candidateIDs):
            state.updateMac(macID) { mac in
                let removed = mac.cleanupCandidates.filter { candidateIDs.contains($0.id) }
                mac.freeBytes += removed.reduce(Int64(0)) { $0 + $1.bytes }
                mac.cleanupCandidates.removeAll { candidateIDs.contains($0.id) }
            }

        default:
            break
        }
    }

    private func acceptAllDecisions(epicID: Epic.ID) {
        let date = now()
        state.updateEpic(epicID) { epic in
            guard var review = epic.finalReview else {
                return
            }
            for index in review.decisions.indices where review.decisions[index].needsReview {
                review.decisions[index].response = .accepted
            }
            review.reviewedHeadCommit = review.headCommit
            epic.finalReview = review
            epic.log("残りの判断をまとめて OK にしました", at: date)
        }
    }

    private func handOver(epicID: Epic.ID, macID: Mac.ID) {
        let date = now()
        let name = state.mac(macID)?.name ?? macID
        state.updateEpic(epicID) { epic in
            epic.macID = macID
            epic.blocker = nil
            epic.activities = []
            epic.log("\(name) に引き継ぎました", at: date)
        }
        state.recordLastMac(macID, forEpic: epicID)
        resumeImplementation(epicID: epicID)
    }

    private func pause(epicID: Epic.ID) {
        let date = now()
        state.updateEpic(epicID) { epic in
            epic.activities = [EpicActivity(kind: .paused(macID: epic.macID ?? "", since: date), since: date)]
            epic.log("一時停止しました", at: date)
        }
    }

    private func resume(epicID: Epic.ID) {
        let date = now()
        state.updateEpic(epicID) { epic in
            epic.removeActivities {
                if case .paused = $0 {
                    return true
                }
                return false
            }
            epic.log("再開しました", at: date)
        }
    }

    private func respond(epicID: Epic.ID, decisionID: DecisionCard.ID, reply: DecisionReply) {
        let date = now()
        state.updateEpic(epicID) { epic in
            switch reply {
            case .accept:
                epic.updateDecision(decisionID) { $0.response = .accepted }
                if let review = epic.finalReview, review.decisions.allSatisfy(\.isConfirmed) {
                    epic.finalReview?.reviewedHeadCommit = review.headCommit
                }

            case .alternative(let text), .fix(let text):
                epic.updateDecision(decisionID) { $0.response = .fixing(request: text) }
                epic.finalReview?.reviewedHeadCommit = nil
                epic.log("判断のカードの直しを頼みました", at: date)
            }
        }
        guard case .accept = reply else {
            schedule(after: 2) { [now] snapshot in
                snapshot.updateEpic(epicID) { epic in
                    epic.updateDecision(decisionID) { decision in
                        guard case .fixing(let request) = decision.response else {
                            return
                        }
                        decision.response = .refreshed(note: "直しました: \(request)")
                    }
                    epic.finalReview?.headCommit = String(UUID().uuidString.prefix(7)).lowercased()
                    epic.log("判断のカードを直し、スクショを撮り直しました", at: now())
                }
            }
            return
        }
    }

    private func merge(epicID: Epic.ID, headCommit: String) {
        let date = now()
        state.updateEpic(epicID) { epic in
            guard epic.finalReview?.headCommit == headCommit else {
                return
            }
            epic.finalReview?.state = .merging
            epic.activities = [EpicActivity(kind: .merging, since: date)]
        }
        schedule(after: 0.5) { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                guard epic.finalReview?.state == .merging else {
                    return
                }
                epic.finalReview?.state = .merged(at: now(), automatic: false)
                epic.stage = .done
                epic.activities = []
                epic.log("マージしました（#\(epic.finalReview?.pullRequestNumber ?? 0)）", at: now())
            }
        }
    }

    /// 最終 PR への指示。直している間は確かめられず、直したら head が替わる
    private func instructFinal(epicID: Epic.ID, headCommit: String, instruction: String) {
        let date = now()
        state.updateEpic(epicID) { epic in
            guard epic.finalReview?.state == .reviewable, epic.finalReview?.headCommit == headCommit else {
                return
            }
            epic.finalReview?.state = .checking
            epic.finalReview?.checks.ci = .fixingByRequest
            epic.finalReview?.reviewedHeadCommit = nil
            epic.log("最終 PR に指示しました: \(instruction)", at: date)
        }
        schedule(after: 2) { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                guard epic.finalReview?.state == .checking else {
                    return
                }
                epic.finalReview?.state = .reviewable
                epic.finalReview?.checks.ci = .passed
                epic.finalReview?.headCommit = String(UUID().uuidString.prefix(7)).lowercased()
                epic.log("最終 PR を指示のとおりに直しました", at: now())
            }
        }
    }

    private func resolveBlocker(epicID: Epic.ID, action: Blocker.Action, instruction: String) {
        let date = now()
        switch action {
        case .pause:
            pause(epicID: epicID)

        case .discard:
            state.epics.removeAll { $0.id == epicID }

        case .handOver:
            break

        case .cancelJob:
            state.updateEpic(epicID) { epic in
                epic.log("\(epic.blocker?.subject ?? "止まっていた作業")をやめました", at: date)
                epic.blocker = nil
            }

        case .fixWithInstruction, .retry, .resumeAfterFix:
            state.updateEpic(epicID) { epic in
                let attempt = (epic.blocker?.attempts.count ?? 0) + 1
                epic.blocker = nil
                if let failed = epic.tasks.firstIndex(where: \.isFailed) {
                    epic.startTask(at: failed, attempt: attempt, date: date)
                }
                epic.log(instruction.isEmpty ? "もう一度直させました" : "指示を添えて直させました: \(instruction)", at: date)
            }
            resumeImplementation(epicID: epicID)
        }
    }

    /// いま進めているタスクを、少し後にマージした扱いにする
    private func resumeImplementation(epicID: Epic.ID) {
        let number = nextPullRequest()
        schedule(after: 1.5) { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                guard let index = epic.tasks.firstIndex(where: { $0.isInProgress || $0.isFailed }) else {
                    return
                }
                epic.tasks[index].state = .done(pullRequest: number)
                epic.activities = []
                epic.log("タスク \(epic.tasks[index].number) をマージしました（#\(number)）", at: now())
                if let next = epic.tasks.firstIndex(where: { $0.state == .pending }) {
                    epic.startTask(at: next, attempt: 1, date: now())
                }
            }
        }
    }

    private func completeHumanTask(epicID: Epic.ID, taskID: HumanTask.ID) {
        let date = now()
        state.updateEpic(epicID) { epic in
            guard let index = epic.humanTasks.firstIndex(where: { $0.id == taskID }) else {
                return
            }
            epic.humanTasks[index].state = .verifying
            epic.log("「\(epic.humanTasks[index].title)」を終えました。確かめています", at: date)
        }
        schedule { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                guard let index = epic.humanTasks.firstIndex(where: { $0.id == taskID }) else {
                    return
                }
                epic.humanTasks[index].state = .done
                for taskIndex in epic.tasks.indices where epic.humanTasks[index].blocksTaskIDs.contains(epic.tasks[taskIndex].id) {
                    if case .locked = epic.tasks[taskIndex].state {
                        epic.tasks[taskIndex].state = .pending
                    }
                }
                epic.log("「\(epic.humanTasks[index].title)」を確かめ、ロックを外しました", at: now())
            }
        }
    }

    private func verify(epicID: Epic.ID, itemID: VerificationItem.ID, reply: VerificationReply) {
        let date = now()
        state.updateEpic(epicID) { epic in
            guard var review = epic.finalReview, let index = review.verifications.firstIndex(where: { $0.id == itemID }) else {
                return
            }
            switch reply {
            case .confirmed:
                review.verifications[index].state = .confirmed

            case .problem(let note):
                review.verifications[index].state = .problem(note: note)
                epic.log("実機確認で問題を見つけ、新しい依頼にしました", at: date)
            }
            epic.finalReview = review
        }
    }
}
