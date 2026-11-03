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
        // 秘密と鍵の置き場所（Keychain・Secure Enclave の署名の鍵・確かめた公開鍵の一覧）
        .library(name: "AskHubKeychain", targets: ["AskHubKeychain"]),
        // macOS で launchd から常駐させる CLI。アプリからは使わない
        .executable(name: "askhub-orchestrator", targets: ["askhub-orchestrator"]),
    ],
    targets: [
        .target(name: "AskHubKit"),
        // 外部の依存を持たない。リポジトリ直下の protocol/ の JSON Schema とテスト用の例が正本
        .target(name: "AskHubProtocol"),
        .target(name: "AskHubKeychain", dependencies: ["AskHubProtocol"]),
        // オーケストレーターのロジック（設定・状態判定）。テストできるよう executable から分ける
        .target(name: "OrchestratorKit", dependencies: ["AskHubKit"]),
        .executableTarget(name: "askhub-orchestrator", dependencies: ["AskHubKit", "OrchestratorKit"]),
        .testTarget(name: "AskHubKitTests", dependencies: ["AskHubKit"]),
        .testTarget(name: "AskHubProtocolTests", dependencies: ["AskHubProtocol"]),
        .testTarget(name: "OrchestratorKitTests", dependencies: ["OrchestratorKit"]),
    ]
)
