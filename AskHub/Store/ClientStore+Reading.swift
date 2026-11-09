import Foundation

extension ClientStore {
    var inboxItems: [InboxItem] {
        guard let snapshot else {
            return []
        }
        return InboxBuilder.items(from: snapshot, now: currentDate())
    }

    var blockingCount: Int {
        inboxItems.filter { $0.urgency == .blocking }.count
    }

    func deckCards(_ scope: DeckScope) -> [DeckCard] {
        guard let snapshot else {
            return []
        }
        // 答えを送ったカードは、反映されるまで山札から外す（断られたら戻す）
        return DeckBuilder.cards(from: snapshot, scope: scope).filter { reflection(for: [$0.target])?.isPending != true }
    }

    func epic(_ id: Epic.ID) -> Epic? {
        snapshot?.epic(id)
    }

    func repository(_ id: TargetRepository.ID?) -> TargetRepository? {
        guard let id else {
            return nil
        }
        return snapshot?.repository(id)
    }

    func mac(_ id: Mac.ID?) -> Mac? {
        snapshot?.mac(id)
    }
}

// MARK: - 反映中

extension ClientStore {
    /// 対象の、送った意図が反映されるまでの様子。複数の対象なら、反映を待っているものを先に返す。何も無ければ nil
    func reflection(for targets: [IntentTarget]) -> Reflection? {
        guard !targets.isEmpty else {
            return nil
        }
        return reflections.reflection(matching: { targets.contains($0) }, pending: pending?.intent)
    }

    /// epic への操作（質問・判断・ゴール・epic の操作など、どれでも）の様子。一覧の行の印に使う
    func reflection(forEpic epicID: Epic.ID) -> Reflection? {
        reflections.reflection(matching: { $0.epicID == epicID }, pending: pending?.intent)
    }

    /// 意図の対象に、反映を待っている操作があるか（あれば、その操作のボタンを押せなくする）
    func isReflecting(_ intent: HumanIntent) -> Bool {
        isReflecting(intent.targets)
    }

    /// 対象に、反映を待っている操作があるか（あれば、その対象への操作を押せなくする）
    func isReflecting(_ targets: [IntentTarget]) -> Bool {
        reflection(for: targets)?.isPending == true
    }

    /// 対象に、操作した場所で知らせることがあるか（司令塔が断った・しばらく受け取っていない）。
    /// 同期を待っているだけなら false（行やカードの隅の小さな印だけを出す）
    func needsAttention(_ targets: [IntentTarget]) -> Bool {
        reflection(for: targets)?.needsAttention(now: currentDate(), threshold: stallThreshold) == true
    }

    /// 司令塔が断った知らせ（古い順）。帯で 1 つずつ出し、対象の場所にも出す
    var rejections: [ReflectionTracker.Rejection] {
        reflections.rejections
    }
}
