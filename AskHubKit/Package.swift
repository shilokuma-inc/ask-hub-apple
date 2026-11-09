// swift-tools-version: 6.0
import PackageDescription

// アプリ（iOS / macOS）と司令塔・ワーカー・非常口（macOS の CLI）で共有するコード。
let package = Package(
    name: "AskHubKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // アプリの添付の上限と種類・本文の描画・GitHub のトークンの保存。今の仕組みのライブラリのうち、アプリが使う部分だけを残した
        .library(name: "AskHubKit", targets: ["AskHubKit"]),
        // リニューアルのプロトコル（人の意図の署名・目印・状態リポジトリの型）。docs/renewal/protocol.md
        .library(name: "AskHubProtocol", targets: ["AskHubProtocol"]),
        // 状態リポジトリの読み書き（GitHub の Contents API・ETag・版の確認・書き込みの予算）
        .library(name: "AskHubStateStore", targets: ["AskHubStateStore"]),
        // 秘密と鍵の置き場所（Keychain・Secure Enclave の署名の鍵・確かめた公開鍵の一覧）
        .library(name: "AskHubKeychain", targets: ["AskHubKeychain"]),
        // ジョブと試行の段取り（失敗の区分ごとの扱い・生きている印の古さ・引き受け）。司令塔とワーカーで使う
        .library(name: "AskHubJobs", targets: ["AskHubJobs"]),
        // epic の段取り（質問の回答・依存のロック・見直し）。司令塔で使う
        .library(name: "AskHubEpics", targets: ["AskHubEpics"]),
        // 制限時間つきでコマンドを流す（子孫のプロセスまで止める）。司令塔とワーカーで使う
        .library(name: "AskHubCommands", targets: ["AskHubCommands"]),
        // Claude を呼ぶ部品（決まった形の結果・直させる・失敗の区分）。司令塔とワーカーで使う
        .library(name: "AskHubClaude", targets: ["AskHubClaude"]),
        // ワーカーが Claude の代わりにビルドとテストを流す（設定・Simulator の枠・xcodebuild・結果の要約・失敗の区分）
        .library(name: "AskHubBuild", targets: ["AskHubBuild"]),
        // クライアントと非常口の段取り（人の意図の署名と送信・公開鍵の記録）
        .library(name: "AskHubClient", targets: ["AskHubClient"]),
        // 司令塔の段取り（Claude に頼むジョブの依頼の文と結果の形）と、ワーカーと共有する Mac の部品
        // （設定・Keychain の持ち主ごとのトークン・作業場所・ジョブの実行と試行の記録）
        .library(name: "AskHubCommander", targets: ["AskHubCommander"]),
        // ワーカーの常駐のループ（自分宛てのジョブを引き受けて試行を書き、生きている印を書く）。開始のときに人が選んだ Mac で使う
        .library(name: "AskHubWorker", targets: ["AskHubWorker"]),
        // ワーカーが子 PR と最終 PR を扱う GitHub の操作（作る・CI とレビューを読む・流し直す・マージ）
        .library(name: "AskHubPullRequests", targets: ["AskHubPullRequests"]),
        // リニューアルの司令塔（常時オンの Mac で LaunchAgent として常駐させる CLI）
        .executable(name: "askhub-commander", targets: ["askhub-commander"]),
        // リニューアルのワーカー（常駐できる Mac は LaunchAgent、できない Mac はターミナルで流し続ける CLI）
        .executable(name: "askhub-worker", targets: ["askhub-worker"]),
        // 非常口（Mac の端末から人の意図に署名して送る CLI）
        .executable(name: "askhub", targets: ["askhub"]),
    ],
    targets: [
        .target(name: "AskHubKit"),
        // 外部の依存を持たない。リポジトリ直下の protocol/ の JSON Schema とテスト用の例が正本
        .target(name: "AskHubProtocol"),
        .target(name: "AskHubStateStore", dependencies: ["AskHubProtocol"]),
        .target(name: "AskHubKeychain", dependencies: ["AskHubProtocol"]),
        .target(name: "AskHubJobs", dependencies: ["AskHubProtocol", "AskHubStateStore"]),
        .target(name: "AskHubEpics", dependencies: ["AskHubProtocol"]),
        .target(name: "AskHubCommands"),
        .target(name: "AskHubClaude", dependencies: ["AskHubCommands", "AskHubProtocol"]),
        .target(name: "AskHubBuild", dependencies: ["AskHubCommands", "AskHubProtocol"]),
        .target(name: "AskHubClient", dependencies: ["AskHubKeychain", "AskHubProtocol", "AskHubStateStore"]),
        .target(
            name: "AskHubCommander",
            dependencies: [
                "AskHubBuild", "AskHubClaude", "AskHubCommands", "AskHubEpics", "AskHubJobs", "AskHubKeychain", "AskHubProtocol",
                "AskHubPullRequests", "AskHubStateStore"
            ]
        ),
        .target(name: "AskHubWorker", dependencies: ["AskHubCommander", "AskHubJobs", "AskHubProtocol", "AskHubStateStore"]),
        .target(name: "AskHubPullRequests", dependencies: ["AskHubProtocol", "AskHubStateStore"]),
        .executableTarget(name: "askhub", dependencies: ["AskHubClient", "AskHubKeychain", "AskHubProtocol", "AskHubStateStore"]),
        .executableTarget(
            name: "askhub-commander",
            dependencies: ["AskHubClaude", "AskHubCommander", "AskHubCommands", "AskHubKeychain", "AskHubProtocol", "AskHubStateStore"]
        ),
        .executableTarget(name: "askhub-worker", dependencies: ["AskHubCommander", "AskHubWorker", "AskHubProtocol", "AskHubStateStore"]),
        .testTarget(name: "AskHubKitTests", dependencies: ["AskHubKit"]),
        .testTarget(name: "AskHubProtocolTests", dependencies: ["AskHubProtocol"]),
        .testTarget(name: "AskHubStateStoreTests", dependencies: ["AskHubStateStore", "AskHubProtocol"]),
        .testTarget(name: "AskHubKeychainTests", dependencies: ["AskHubKeychain", "AskHubProtocol"]),
        .testTarget(name: "AskHubJobsTests", dependencies: ["AskHubJobs", "AskHubStateStore", "AskHubProtocol"]),
        .testTarget(name: "AskHubEpicsTests", dependencies: ["AskHubEpics", "AskHubProtocol"]),
        .testTarget(name: "AskHubCommandsTests", dependencies: ["AskHubCommands"]),
        .testTarget(name: "AskHubClaudeTests", dependencies: ["AskHubClaude", "AskHubCommands", "AskHubProtocol"]),
        .testTarget(name: "AskHubBuildTests", dependencies: ["AskHubBuild", "AskHubCommands", "AskHubProtocol"]),
        .testTarget(
            name: "AskHubClientTests",
            dependencies: ["AskHubClient", "AskHubCommander", "AskHubKeychain", "AskHubProtocol", "AskHubStateStore"]
        ),
        .testTarget(
            name: "AskHubCommanderTests",
            dependencies: [
                "AskHubCommander", "AskHubBuild", "AskHubClaude", "AskHubCommands", "AskHubEpics", "AskHubKeychain", "AskHubProtocol",
                "AskHubPullRequests", "AskHubStateStore"
            ]
        ),
        .testTarget(
            name: "AskHubWorkerTests",
            dependencies: ["AskHubWorker", "AskHubCommander", "AskHubCommands", "AskHubJobs", "AskHubProtocol", "AskHubStateStore"]
        ),
        .testTarget(name: "AskHubPullRequestsTests", dependencies: ["AskHubPullRequests", "AskHubProtocol", "AskHubStateStore"]),
    ]
)
