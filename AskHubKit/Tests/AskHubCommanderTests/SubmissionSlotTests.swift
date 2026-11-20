@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// App Store Connect の版の枠（リリースを始めたときに作り、ビルドと What's New を入れ、やめたら消す）
extension ReleaseWatchTests {
    /// この仕組みの後に始めた版（枠を作る印の空の並びを持つ）
    func startReleaseWithSlots() async throws {
        try await startRelease()
        var file = SubmissionHandlersTests.started()
        file.appStoreVersions = []
        try await putSubmission(file)
        appStore.state.withLock { state in
            state.localizations["v-1-2-0"] = [
                AppStoreLocalization(id: "s-ja", locale: "ja", whatsNew: nil),
                AppStoreLocalization(id: "s-en", locale: "en-US", whatsNew: nil)
            ]
        }
    }

    func slotWrites() -> [String] {
        appStore.state.withLock { $0.writes }
    }

    @Test func createsSlotAndFillsWhatsNewWhenStarted() async throws {
        try await startReleaseWithSlots()
        let watch = watch()
        await watch.refresh()
        // 承認後すぐの版を、ビルドを選ばずに作り、下書きした What's New を書く
        #expect(slotWrites() == [
            "createVersion iOS 1.2.0 afterApproval -",
            "updateWhatsNew s-ja ・ja の新しい機能",
            "updateWhatsNew s-en ・en-US の新しい機能"
        ])
        var file = try await submission()
        #expect(file.appStoreVersions == [.init(platform: .iOS, id: "v-1-2-0", whatsNew: true, at: Timestamp(Self.now))])

        // release ブランチから上げたビルドを見つけたら、枠に選ぶ（配信の方式は送らない）
        appStore.state.withLock { $0.builds = [build("45", minutesFromNow: 5)] }
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(slotWrites().last == "updateVersion v-1-2-0 1.2.0 - b45")
        file = try await submission()
        #expect(file.appStoreVersions?.first?.build == "45")
        // 同じビルドなら選び直さない・What's New は 1 回だけ書く
        let count = slotWrites().count
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(slotWrites().count == count)
    }

    @Test func usesEditableVersionOfTheSameNumber() async throws {
        try await startReleaseWithSlots()
        appStore.state.withLock { state in
            state.others = [AppStoreVersionInfo(id: "v-hand", platform: .iOS, versionString: "1.2.0", state: .prepareForSubmission)]
            state.localizations["v-hand"] = [AppStoreLocalization(id: "h-ja", locale: "ja", whatsNew: "・ja の新しい機能")]
        }
        await watch().refresh()
        // 作らない。同じ文なら書かない
        #expect(slotWrites().isEmpty)
        #expect(try await submission().appStoreVersions?.map(\.id) == ["v-hand"])
    }

    @Test func refusesWhenAnotherEditableVersionExists() async throws {
        try await startReleaseWithSlots()
        appStore.state.withLock { state in
            state.others = [AppStoreVersionInfo(id: "v-old", platform: .iOS, versionString: "1.1.9", state: .developerRejected)]
        }
        let watch = watch()
        await watch.refresh()
        #expect(slotWrites().isEmpty)
        let file = try await submission()
        #expect(file.appStoreVersions?.isEmpty == true)
        #expect(file.problem?.step == .appStoreVersion && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("1.1.9") == true)
        #expect(await submissionBlockers(watch).map(\.reason) == [.submissionProblem(.appStoreVersion)])
    }

    @Test func deletesUnsubmittedSlotsWhenAbandoned() async throws {
        try await startReleaseWithSlots()
        var file = SubmissionHandlersTests.started()
        file.appStoreVersions = [.init(platform: .iOS, id: "v-1-2-0", at: Timestamp(Self.now))]
        file.end = .init(reason: .abandoned, at: Timestamp(Self.now), approval: file.start?.approval)
        try await putSubmission(file)
        appStore.state.withLock { $0.others = [self.version(.prepareForSubmission)] }
        let watch = watch()
        await watch.refresh()
        #expect(slotWrites() == ["deleteVersion v-1-2-0"])
        #expect(try await submission().appStoreVersions?.first?.removal == .deleted)
        #expect(await submissionBlockers(watch).isEmpty)
        // 消した後は、もう消さない
        await watch.refresh()
        #expect(slotWrites().count == 1)
    }

    @Test func keepsSlotsThatCannotBeDeleted() async throws {
        try await startReleaseWithSlots()
        var file = SubmissionHandlersTests.started()
        file.appStoreVersions = [.init(platform: .iOS, id: "v-1-2-0", at: Timestamp(Self.now))]
        file.end = .init(reason: .abandoned, at: Timestamp(Self.now), approval: file.start?.approval)
        try await putSubmission(file)
        appStore.state.withLock { state in
            state.others = [self.version(.developerRejected)]
            state.refusal = .refused(status: 409, detail: "The version can't be deleted.")
        }
        let watch = watch()
        await watch.refresh()
        let slot = try #require(try await submission().appStoreVersions?.first)
        #expect(slot.removal == .kept)
        #expect(slot.removalNote?.contains("The version can't be deleted.") == true)
        #expect(await submissionBlockers(watch).map(\.reason) == [.slotKept(.iOS)])
    }
}

extension SubmissionHandlersTests {
    @Test func startMarksTheSlotsToBeCreated() async throws {
        try await addRepository()
        #expect(try await StartReleaseHandler().handle(envelope("startRelease"), in: context) == .accept)
        #expect(try await file()?.appStoreVersions?.isEmpty == true)
    }
}
