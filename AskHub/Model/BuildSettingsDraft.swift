import AskHubProtocol
import Foundation

/// 対象のリポジトリのビルドの設定（`repo.json` の `build`）のうち、画面に出す要点と、直すときの元の JSON
struct RepositoryBuildSettings: Hashable {
    var scheme: String
    /// 流す行き先（「iPhone 17 Pro（iOS 26.5）」「Mac」）
    var destinations: [String]
    var childChecks: [String]
    var finalChecks: [String]
    /// 直すときの元（字下げした JSON）
    var json: String
}

/// ビルドの設定を直す下書き。主な欄はフォームで直し、ほかの欄（テストの絞り込み・スクショなど）は JSON で直す。
/// フォームの欄だけを元の JSON に書き戻すので、フォームに出さない欄は消えない。送る前の確かめは、司令塔と同じ決まり（`ConfigureRepositoryIntent.build(from:)`）で行う
struct BuildSettingsDraft: Equatable {
    struct Destination: Identifiable, Equatable {
        let id = UUID()
        var platform: String
        var deviceType = ""
        var osVersion = ""
    }

    static let platforms = ["iOS", "visionOS", "macOS"]

    var baseBranch: String
    var project: String
    var scheme: String
    /// プロジェクトを XcodeGen で作る（`xcode.generate` が `xcodegen`）
    var usesXcodeGen: Bool
    var destinations: [Destination]
    /// 待つチェックの名前・信用するレビューの書き手（1 行に 1 つ）
    var childChecks: String
    var finalChecks: String
    var trustedReviewers: String
    /// 元の JSON（フォームに出さない欄を残す）
    private var base: [String: JSONValue]

    /// `json` は今の設定。無い・読めないときは、よく使う形から始める
    init(json: String?) {
        let object = json.flatMap { try? JSONValue(parsing: $0) }.flatMap { value -> [String: JSONValue]? in
            guard case let .object(object) = value else { return nil }
            return object
        }
        base = object ?? [:]
        let xcode = object?["xcode"]
        baseBranch = object?["baseBranch"]?.stringValue ?? "develop"
        project = xcode?["project"]?.stringValue ?? ""
        scheme = xcode?["scheme"]?.stringValue ?? ""
        usesXcodeGen = xcode?["generate"]?.stringValue == "xcodegen"
        if case let .array(items)? = xcode?["destinations"] {
            destinations = items.map { item in
                Destination(
                    platform: item["platform"]?.stringValue ?? "iOS",
                    deviceType: item["deviceType"]?.stringValue ?? "",
                    osVersion: item["osVersion"]?.stringValue ?? ""
                )
            }
        } else {
            destinations = [Destination(platform: "iOS", deviceType: "iPhone 17 Pro")]
        }
        childChecks = Self.lines(object?["childChecks"]) ?? "build / build"
        finalChecks = Self.lines(object?["finalChecks"]) ?? "build / build"
        trustedReviewers = Self.lines(object?["trustedReviewers"]) ?? ""
    }

    /// フォームの欄を元の JSON に書き戻したもの
    var value: JSONValue {
        var object = base
        object["baseBranch"] = baseBranch.trimmed.isEmpty ? nil : .string(baseBranch.trimmed)
        var xcode: [String: JSONValue] = if case let .object(current)? = base["xcode"] { current } else { [:] }
        xcode["project"] = .string(project.trimmed)
        xcode["scheme"] = .string(scheme.trimmed)
        xcode["generate"] = usesXcodeGen ? .string("xcodegen") : nil
        xcode["destinations"] = .array(destinations.map(Self.value))
        object["xcode"] = .object(xcode)
        object["childChecks"] = Self.list(childChecks)
        object["finalChecks"] = Self.list(finalChecks)
        object["trustedReviewers"] = Self.list(trustedReviewers)
        return .object(object)
    }

    /// 字下げした JSON（JSON で直すときに出す）
    var text: String {
        Self.pretty(value)
    }

    /// JSON の object として読めるか（読めなければ、フォームに戻すと直した中身を失う）
    static func isJSONObject(_ text: String) -> Bool {
        if case .object? = try? JSONValue(parsing: text) {
            return true
        }
        return false
    }

    static func pretty(_ value: JSONValue) -> String {
        let data = CanonicalJSON.data(for: value)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(bytes: pretty, encoding: .utf8) else {
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        return text
    }

    private static func value(of destination: Destination) -> JSONValue {
        guard destination.platform != "macOS" else {
            return .object(["platform": .string("macOS")])
        }
        var object: [String: JSONValue] = ["platform": .string(destination.platform), "deviceType": .string(destination.deviceType.trimmed)]
        if !destination.osVersion.trimmed.isEmpty {
            object["osVersion"] = .string(destination.osVersion.trimmed)
        }
        return .object(object)
    }

    private static func lines(_ value: JSONValue?) -> String? {
        guard case let .array(items)? = value else {
            return nil
        }
        return items.compactMap(\.stringValue).joined(separator: "\n")
    }

    private static func list(_ text: String) -> JSONValue {
        .array(text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }.map(JSONValue.string))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
