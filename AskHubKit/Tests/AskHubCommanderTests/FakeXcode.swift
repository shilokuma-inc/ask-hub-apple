import Foundation

/// 一時フォルダに作る偽の Xcode（`Xcode-<版>.app/Contents/Developer/usr/bin` の `xcrun` と `xcodebuild`）。
///
/// `/usr/bin/xcrun` は `DEVELOPER_DIR` の下の `usr/bin/xcrun` に渡すので、本物の `xcrun` で流しても、この中の `xcodebuild` が動く。
/// `xcodebuild` は、`-version` なら版を出し、ほかは受け取った引数を `calls` に 1 行ずつ書いて成功する
struct FakeXcode {
    let root: URL
    let app: URL

    var developerDirectory: URL { app.appendingPathComponent("Contents/Developer", isDirectory: true) }
    /// `xcodebuild` が受け取った引数（1 回で 1 行）
    var calls: URL { root.appendingPathComponent("xcodebuild-calls") }

    init(version: String = "99.1") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-fake-xcode-\(UUID().uuidString)", isDirectory: true)
        app = root.appendingPathComponent("Xcode-\(version).app", isDirectory: true)
        let bin = developerDirectory.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.script("tool=\"$1\"\nshift\nexec \"$(dirname \"$0\")/$tool\" \"$@\"", at: bin.appendingPathComponent("xcrun"))
        try Self.script(
            """
            if [ "$1" = "-version" ]; then
              echo "Xcode \(version)"
              echo "Build version 99A1"
              exit 0
            fi
            echo "$@" >> '\(calls.path)'
            echo '** BUILD SUCCEEDED **'
            """,
            at: bin.appendingPathComponent("xcodebuild")
        )
    }

    /// `xcodebuild` が受け取った引数。まだ呼ばれていなければ空
    func recordedCalls() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func script(_ body: String, at url: URL) throws {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
