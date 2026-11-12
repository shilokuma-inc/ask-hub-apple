import Foundation

// MARK: - 受け付けの確かめ

extension ClientStore {
    /// 司令塔の受け取りを待つ意図がある間だけ、受け付けの記録を数秒ごとに軽く確かめ、見つけたら全体を読み直す。
    /// 全体の取り直しの間隔は変えない。送ってから `stallThreshold` を過ぎた意図は確かめず、ふだんの取り直しに任せる
    func watchReceipts() {
        guard receiptWatch == nil, let interval = service.receiptCheckInterval, awaitedIntentID() != nil else {
            return
        }
        receiptWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.checkReceipt() else {
                    break
                }
            }
            self?.receiptWatch = nil
        }
    }

    /// 受け付けを確かめる意図。司令塔は番号の順に処理するので、待っているうちで一番前に送ったものだけを確かめる（記録が無い間の読み取りも、上限に数えられる）
    private func awaitedIntentID() -> String? {
        reflections.oldestAwaitingIntentID(sentAfter: currentDate().addingTimeInterval(-stallThreshold))
    }

    /// 1 回確かめる。確かめ続けるなら true
    private func checkReceipt() async -> Bool {
        guard let intentID = awaitedIntentID() else {
            return false
        }
        let date = currentDate()
        if let until = receiptCheckPausedUntil, date < until {
            return true
        }
        do {
            if try await service.hasReceipt(for: intentID) {
                await refresh()
            }
        } catch {
            // 上限に当たったら、言われた間だけ休む。ほかの失敗は、次の間隔で確かめ直す
            if let wait = (error as? ClientServiceError)?.retryAfter {
                receiptCheckPausedUntil = date.addingTimeInterval(TimeInterval(wait.components.seconds))
            }
        }
        return true
    }
}
