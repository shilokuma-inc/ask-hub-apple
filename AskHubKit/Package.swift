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
        // macOS で launchd から常駐させる CLI。アプリからは使わない
        .executable(name: "askhub-orchestrator", targets: ["askhub-orchestrator"]),
    ],
    targets: [
        .target(name: "AskHubKit"),
        // オーケストレーターのロジック（設定・状態判定）。テストできるよう executable から分ける
        .target(name: "OrchestratorKit", dependencies: ["AskHubKit"]),
        .executableTarget(name: "askhub-orchestrator", dependencies: ["OrchestratorKit"]),
        .testTarget(name: "AskHubKitTests", dependencies: ["AskHubKit"]),
        .testTarget(name: "OrchestratorKitTests", dependencies: ["OrchestratorKit"]),
    ]
)
