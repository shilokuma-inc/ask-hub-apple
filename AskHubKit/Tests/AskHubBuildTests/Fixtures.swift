import Foundation

/// `xcrun xcresulttool get build-results` / `get test-results summary` の出力の見本。
/// Xcode 27.1 で、XcodeGen で作った小さなプロジェクト（iOS 26.5 の Simulator）を `LiveBuildTests` で流して書き出したもの
/// （`ASKHUB_LIVE_BUILD_DUMP`）。Simulator の UDID だけ 0 にした
enum Fixtures {
    /// ビルドが通ったときの `build-results`
    static let noErrors = #"""
    {
      "actionTitle": "Testing project Probe with scheme Probe",
      "analyzerWarningCount": 0,
      "analyzerWarnings": [],
      "destination": {
        "architecture": "arm64",
        "deviceId": "00000000-0000-0000-0000-000000000000",
        "deviceName": "askhub-worker-90-iPhone-17-Pro-iOS-26.5",
        "modelName": "iPhone 17 Pro",
        "osBuildNumber": "23F77",
        "osVersion": "26.5",
        "platform": "iOS Simulator"
      },
      "endTime": 1794037043.544,
      "errorCount": 0,
      "errors": [],
      "startTime": 1794037005.069,
      "status": "succeeded",
      "warningCount": 0,
      "warnings": []
    }
    """#

    /// テストが通ったときの `test-results summary`（`devicesAndConfigurations` は JSON Schema と違って配列で返る）
    static let passedSummary = #"""
    {
      "devicesAndConfigurations": [
        {
          "device": {
            "architecture": "arm64",
            "deviceId": "00000000-0000-0000-0000-000000000000",
            "deviceName": "askhub-worker-90-iPhone-17-Pro-iOS-26.5",
            "modelName": "iPhone 17 Pro",
            "osBuildNumber": "23F77",
            "osVersion": "26.5",
            "platform": "iOS Simulator"
          },
          "expectedFailures": 0,
          "failedTests": 0,
          "passedTests": 2,
          "skippedTests": 0,
          "testPlanConfiguration": {"configurationId": "1", "configurationName": "Test Scheme Action"}
        }
      ],
      "environmentDescription": "Probe · Built with macOS 26.7.1",
      "expectedFailures": 0,
      "failedTests": 0,
      "finishTime": 1794037043.544,
      "passedTests": 2,
      "result": "Passed",
      "runtimeWarnings": [],
      "skippedTests": 0,
      "startTime": 1794037005.069,
      "statistics": [],
      "testFailures": [],
      "title": "Test - Probe",
      "topInsights": [],
      "totalTestCount": 2
    }
    """#

    /// Swift Testing と XCTest のテストが 1 件ずつ落ちたときの `test-results summary`。
    /// Swift Testing の失敗の文には、`#expect` に付けたコメント（ここではトークン）がそのまま入る
    static func failedSummary(token: String) -> String {
        #"""
        {
          "devicesAndConfigurations": [],
          "environmentDescription": "Probe · Built with macOS 26.7.1",
          "expectedFailures": 0,
          "failedTests": 2,
          "finishTime": 1794037862.603,
          "passedTests": 0,
          "result": "Failed",
          "runtimeWarnings": [],
          "skippedTests": 0,
          "startTime": 1794037218.498,
          "statistics": [],
          "testFailures": [
            {
              "failureText": "Expectation failed: sum(1, 2) == 4\nsum(1, 2) → 3: TOKEN",
              "targetName": "ProbeTests",
              "testIdentifier": 2,
              "testIdentifierString": "AdditionTests/adds()",
              "testIdentifierURL": "test://com.apple.xcode/Probe/ProbeTests/AdditionTests/adds()",
              "testName": "adds()"
            },
            {
              "failureText": "XCTAssertEqual failed: (\"4\") is not equal to (\"5\")",
              "targetName": "ProbeTests",
              "testIdentifier": 1,
              "testIdentifierString": "LegacyTests/testAdds()",
              "testIdentifierURL": "test://com.apple.xcode/Probe/ProbeTests/LegacyTests/testAdds",
              "testName": "testAdds()"
            }
          ],
          "title": "Test - Probe",
          "topInsights": [],
          "totalTestCount": 2
        }
        """#.replacingOccurrences(of: "TOKEN", with: token)
    }

    /// テストの操作でビルドが失敗したときの `build-results`。`sourceURL` の行は 0 から数える（10 行目が 9）
    static func buildErrors(source: String) -> String {
        #"""
        {
          "actionTitle": "Testing project Probe with scheme Probe",
          "analyzerWarningCount": 0,
          "analyzerWarnings": [],
          "destination": {"architecture": "arm64", "deviceId": "00000000-0000-0000-0000-000000000000", "osVersion": "26.5"},
          "endTime": 1794038800.112,
          "errorCount": 2,
          "errors": [
            {"issueType": "Uncategorized", "message": "Testing cancelled because the build failed."},
            {
              "className": "DVTTextDocumentLocation",
              "issueType": "Swift Compiler Error",
              "message": "Cannot find 'missing' in scope",
              "sourceURL": "file://SOURCE/Probe/ProbeApp.swift#EndingColumnNumber=48&EndingLineNumber=9&StartingColumnNumber=48&StartingLineNumber=9"
            }
          ],
          "startTime": 1794038740.021,
          "status": "failed",
          "warningCount": 0,
          "warnings": []
        }
        """#.replacingOccurrences(of: "SOURCE", with: source)
    }
}
