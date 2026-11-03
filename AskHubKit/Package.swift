// swift-tools-version: 6.0
import PackageDescription

// アプリ（iOS / macOS）とオーケストレーター（macOS の CLI）で共有するコード。
// プロトコル（ラベル・目印・回答形式）のモデルとパーサー、GitHub API クライアントを置く。
let package = Package(
    name: "AskHubKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
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
        // 司令塔の段取り（Claude に頼むジョブの依頼の文と結果の形）。常時オンの Mac で使う
        .library(name: "AskHubCommander", targets: ["AskHubCommander"]),
        // macOS で launchd から常駐させる CLI。アプリからは使わない
        .executable(name: "askhub-orchestrator", targets: ["askhub-orchestrator"]),
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
        .target(name: "AskHubCommander", dependencies: ["AskHubClaude", "AskHubEpics", "AskHubProtocol"]),
        // オーケストレーターのロジック（設定・状態判定）。テストできるよう executable から分ける
        .target(name: "OrchestratorKit", dependencies: ["AskHubKit"]),
        .executableTarget(name: "askhub-orchestrator", dependencies: ["AskHubKit", "OrchestratorKit"]),
        .testTarget(name: "AskHubKitTests", dependencies: ["AskHubKit"]),
        .testTarget(name: "AskHubProtocolTests", dependencies: ["AskHubProtocol"]),
        .testTarget(name: "AskHubStateStoreTests", dependencies: ["AskHubStateStore", "AskHubProtocol"]),
        .testTarget(name: "AskHubKeychainTests", dependencies: ["AskHubKeychain", "AskHubProtocol"]),
        .testTarget(name: "AskHubJobsTests", dependencies: ["AskHubJobs", "AskHubStateStore", "AskHubProtocol"]),
        .testTarget(name: "AskHubEpicsTests", dependencies: ["AskHubEpics", "AskHubProtocol"]),
        .testTarget(name: "AskHubCommandsTests", dependencies: ["AskHubCommands"]),
        .testTarget(name: "AskHubClaudeTests", dependencies: ["AskHubClaude", "AskHubCommands", "AskHubProtocol"]),
        .testTarget(name: "OrchestratorKitTests", dependencies: ["OrchestratorKit"]),
    ]
)
