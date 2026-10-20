@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// 読み取りの失敗と、入力中の本文の残し方（PR #637 の第三者レビュー）
extension ReleaseProgressTests {
    private static let otherRepository = "shilokuma-inc/notti-ios"

    @Test func keepsProgressAndEditedTextWhenReadFails() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        fixture.model.notes.texts["ja"] = "・直した本文"

        // 読み直しに失敗しても、前の進み具合と直した本文は残し（iOS で最新情報の画面を閉じない）、理由を最新情報の画面にも出す
        fixture.reader.fail(refs: .permissionDenied)
        await fixture.model.refresh()
        guard case .failed(let message) = fixture.model.contextState else {
            Issue.record("読めないはず: \(fixture.model.contextState)")
            return
        }
        #expect(fixture.model.notes.repository == Self.repository)
        #expect(fixture.model.notes.progress?.version == Self.version)
        #expect(fixture.model.notes.texts == ["ja": "・直した本文"])
        #expect(fixture.model.notes.readFailure == message)
        #expect(fixture.model.notes.blockingReason() == "リリースの状態を読み直せませんでした。更新してからもう一度確定してください")
        #expect(!fixture.model.notes.canConfirm())

        // 読めたら理由を消す。直した本文は残す
        fixture.reader.fail()
        await fixture.model.refresh()
        #expect(fixture.model.notes.readFailure == nil)
        #expect(fixture.model.notes.texts == ["ja": "・直した本文"])
        #expect(fixture.model.notes.canConfirm())
    }

    @Test func keepsLoadedTextsWhenOnlyNotesFail() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)

        // 最新情報だけ読めなかった。言語と本文は前のまま、確定は止める
        fixture.reader.fail(notes: .invalidContent(path: "AppStore/whats-new-draft.json"))
        await fixture.model.refresh()
        #expect(fixture.model.notes.languages == ["ja"])
        #expect(fixture.model.notes.texts == ["ja": "・通知を直しました"])
        #expect(!fixture.model.notes.isEdited)
        #expect(fixture.model.notes.blockingReason() == "AppStore/whats-new-draft.json を読めませんでした")

        // 次に読めたら、直していない本文は新しい下書きに入れ替える（古い本文を「直した本文」として残さない）
        fixture.reader.fail()
        fixture.reader.set(status: .draft(Self.draft(text: "・新しい下書き")))
        await fixture.model.refresh()
        #expect(fixture.model.notes.texts == ["ja": "・新しい下書き"])
        #expect(!fixture.model.notes.isEdited)
    }

    @Test func keepsEditedTextPerRelease() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        fixture.model.notes.texts["ja"] = "・A で直した本文"

        // 別のリポジトリでは、そのリリースの下書きを出す
        await fixture.model.select(Self.otherRepository)
        #expect(fixture.model.notes.repository == Self.otherRepository)
        #expect(fixture.model.notes.texts == ["ja": "・通知を直しました"])
        #expect(!fixture.model.notes.isEdited)

        // 戻ってきたら、直した本文を戻す
        await fixture.model.select(Self.repository)
        #expect(fixture.model.notes.texts == ["ja": "・A で直した本文"])
        #expect(fixture.model.notes.isEdited)

        // 選択を外して戻っても残す
        await fixture.model.select(nil)
        #expect(!fixture.model.notes.isReading)
        await fixture.model.select(Self.repository)
        #expect(fixture.model.notes.texts == ["ja": "・A で直した本文"])
    }

    @Test func dropsEditedTextOfFinishedRelease() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        fixture.model.notes.texts["ja"] = "・A で直した本文"
        // 別のリポジトリに切り替えると、直した本文を退避する
        await fixture.model.select(Self.otherRepository)
        #expect(fixture.model.notes.editingByRelease.keys.sorted() == ["\(Self.repository) 1.1.0"])

        // A のリリースが終わってタグができたら、戻す先が無いので捨てる
        fixture.reader.finishRelease()
        await fixture.model.select(Self.repository)
        #expect(fixture.model.notes.progress == nil)
        #expect(fixture.model.notes.texts.isEmpty)
        #expect(fixture.model.notes.editingByRelease.isEmpty)
    }

    @Test func dropsEditedTextWhenReleaseFinishesWhileShown() async {
        let fixture = makeFixture()
        await fixture.model.select(Self.repository)
        fixture.model.notes.texts["ja"] = "・A で直した本文"

        // 見ているあいだにリリースが終わった
        fixture.reader.finishRelease()
        await fixture.model.refresh()
        #expect(fixture.model.notes.progress == nil)
        #expect(!fixture.model.notes.isEdited)
        #expect(fixture.model.notes.editingByRelease.isEmpty)
    }

    @Test func choosesPrepareRunOfVersion() async {
        let fixture = makeFixture()
        // 直近の run は別のバージョン（ブランチを切る前に失敗したものなど）
        let other = Self.run(id: 2, branch: "develop", conclusion: .failure, title: "Release/Prepare 1.2.0")
        let own = Self.run(id: 1, branch: "develop", title: "Release/Prepare 1.1.0")
        fixture.prepare.update { $0.runs = [other, own] }
        await fixture.model.select(Self.repository)
        #expect(fixture.model.context?.latestRun?.id == 2)
        #expect(fixture.model.context?.progress?.prepareRun?.id == 1)
        #expect(statuses(fixture.model)[.prepare] == .done)
    }

    @Test func showsFailureOfReconfirmedNotes() async {
        let fixture = makeFixture()
        fixture.reader.set(status: .confirmed, whatsNew: ["ja": ConfirmedWhatsNew(version: "1.1.0", text: "・確定")])
        let failed = Self.run(id: 3, branch: "release/1.1.0", conclusion: .failure)
        fixture.notes.update { $0.runs = [failed] }
        await fixture.model.select(Self.repository)
        let step = fixture.model.context?.progress?.steps.first { $0.id == .notes }
        #expect(step?.status == .failed)
        #expect(step?.detail.hasPrefix("最新情報を確定し直した run が失敗しました。") == true)
    }

    @Test func describesReadFailuresByWorkflow() async {
        let fixture = makeFixture()
        fixture.upload.update { $0.readFailure = .dispatchNotSupported(message: nil) }
        fixture.finish.update { $0.readFailure = .workflowNotFound }
        await fixture.model.select(Self.repository)
        let detail = { (kind: ReleaseStep.Kind) in fixture.model.context?.progress?.steps.first { $0.id == kind }?.detail }
        #expect(detail(.upload) == "アップロードの run を読めませんでした")
        #expect(detail(.finish)?.hasPrefix("このリポジトリにはリリース後作業のワークフロー（release-finish.yml）がありません") == true)
        #expect(detail(.finish)?.contains("release-prepare.yml") == false)
    }
}
