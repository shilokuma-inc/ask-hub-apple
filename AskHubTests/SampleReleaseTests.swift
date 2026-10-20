@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// デモモードのリリースのサンプル（各状態と、起動したことにした run の進み方）
extension ReleaseProgressTests {
    @Test func sampleShowsEachStateOfRelease() async {
        let model = ReleaseRequestModel.sample()

        // 準備中: リリース準備の run が実行中で、下書きはまだ無い
        await model.select(SampleReleaseReader.preparingRepository)
        #expect(statuses(model)[.prepare] == .running)
        #expect(statuses(model)[.upload] == .notStarted)
        #expect(model.notes.blockingReason() == "リリース準備の run が実行中です。終わってから確定してください")

        // 下書きあり
        await model.select(SampleReleaseReader.draftRepository)
        #expect(statuses(model)[.notes] == .waiting)
        #expect(statuses(model)[.distribution] == .notStarted)

        // 確定済みで配信待ち
        await model.select(SampleReleaseReader.waitingRepository)
        #expect(statuses(model)[.notes] == .done)
        #expect(statuses(model)[.distribution] == .waiting)
        #expect(statuses(model)[.finish] == .notStarted)
        #expect(model.notes.texts["ja"]?.contains("画像の変換") == true)

        // 完了: リリース後作業の run が成功した
        await model.select(SampleReleaseReader.finishedRepository)
        #expect(statuses(model)[.distribution] == .done)
        #expect(statuses(model)[.finish] == .done)
    }

    @Test func sampleStartedReleaseBecomesPreparingAndThenHasDraft() async {
        let model = ReleaseRequestModel.sample(runDuration: 0)
        await model.select("shilokuma-inc/ask-hub-apple")
        #expect(model.context?.progress == nil)
        await model.start()
        await model.refresh()

        // 始めたリリース準備の release ブランチが準備中のリリースになる。run は終わったことにして、アップロードと下書きに進む
        #expect(model.context?.progress?.version == ReleaseVersion("1.3.0"))
        #expect(model.context?.latestRun?.isSuccessful == true)
        #expect(statuses(model)[.prepare] == .done)
        #expect(statuses(model)[.upload] == .done)
        #expect(statuses(model)[.notes] == .waiting)
        #expect(model.notes.draft?.version == "1.3.0")
        #expect(model.blockingReason()?.contains("release/1.3.0") == true)
    }

    @Test func sampleConfirmedDraftBecomesConfirmed() async {
        let model = ReleaseRequestModel.sample(runDuration: 0)
        await model.select(SampleReleaseReader.draftRepository)
        model.notes.texts["ja"] = "・デモで直した本文"
        await model.notes.confirm()
        await model.refresh()

        // 確定の run が終わったことにして、送った本文で確定済みにする
        #expect(model.context?.progress?.notesWorkflow.run?.isSuccessful == true)
        #expect(model.notes.notes?.status == .confirmed)
        #expect(model.notes.texts == ["ja": "・デモで直した本文"])
        #expect(!model.notes.isEdited)
        #expect(statuses(model)[.notes] == .done)
        #expect(statuses(model)[.distribution] == .waiting)
    }
}
