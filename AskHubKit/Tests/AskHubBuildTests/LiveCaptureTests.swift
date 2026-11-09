#if os(macOS)
import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// 本物の `simctl`・`xcodebuild` で、判断のカードのスクショを撮る。`ASKHUB_LIVE_CAPTURE=1` のときだけ動く。作った Simulator は最後に消す。
///
/// - `ASKHUB_LIVE_CAPTURE_PROJECT`: ビルドする写しのフォルダ
/// - `ASKHUB_LIVE_CAPTURE_SETTINGS`: `BuildSettings` の JSON（`project`・`scheme`。最初の Simulator の行き先で撮る）
/// - `ASKHUB_LIVE_CAPTURE_SCENES`: 撮れる画面の一覧のファイル（写しの中の相対パス）
/// - `ASKHUB_LIVE_CAPTURE_OUTPUT`: 撮った画像を置くフォルダ（見て確かめる）
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ASKHUB_LIVE_CAPTURE"] == "1"), .serialized)
struct LiveCaptureTests {
    /// 人や動いているワーカーの枠と重ならない番号
    static let slot = 91

    @Test func capturesEveryScene() async throws {
        let environment = ProcessInfo.processInfo.environment
        let project = URL(fileURLWithPath: try #require(environment["ASKHUB_LIVE_CAPTURE_PROJECT"]))
        let settings = try JSONDecoder().decode(BuildSettings.self, from: Data(try #require(environment["ASKHUB_LIVE_CAPTURE_SETTINGS"]).utf8))
        let scenesFile = project.appendingPathComponent(try #require(environment["ASKHUB_LIVE_CAPTURE_SCENES"]))
        let scenes = try JSONDecoder().decode(ScreenshotScenesFile.self, from: Data(contentsOf: scenesFile))
        #expect(scenes.problems.isEmpty)
        let output = URL(fileURLWithPath: try #require(environment["ASKHUB_LIVE_CAPTURE_OUTPUT"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-capture-live-\(UUID().uuidString)")
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tools = BuildTools(temporaryDirectory: temporary)
        let pool = SimulatorPool(tools: tools, runner: ProcessCommandRunner())
        let destination = settings.destinations.lazy.compactMap { destination -> SimulatorDestination? in
            if case .simulator(let simulator) = destination { return simulator }
            return nil
        }.first ?? SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")
        let simulator = try await pool.prepare(slot: Self.slot, for: destination)
        var failure: (any Error)?
        do {
            let request = CaptureRequest(
                settings: settings,
                sourceDirectory: project,
                derivedData: root.appendingPathComponent("DerivedData"),
                scenes: scenes.scenes,
                output: output
            )
            let started = Date()
            let outcome = try await ScreenshotCapturer(tools: tools, runner: ProcessCommandRunner()).capture(request, on: simulator)
            print("[live] \(Int(Date().timeIntervalSince(started))) 秒: 撮れた \(outcome.images.keys.sorted())・撮れなかった \(outcome.failures)・\(outcome.problem ?? "")")
            #expect(outcome.problem == nil)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.images.count == scenes.scenes.count)
        } catch {
            failure = error
        }
        let others = Set(try await pool.workerSimulators().map(\.name)).subtracting([simulator.name])
        _ = try await pool.removeStray(keeping: others)
        if let failure { throw failure }
    }
}
#endif
