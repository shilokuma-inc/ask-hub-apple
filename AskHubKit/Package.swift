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
    ],
    targets: [
        .target(name: "AskHubKit"),
        .testTarget(name: "AskHubKitTests", dependencies: ["AskHubKit"]),
    ]
)
