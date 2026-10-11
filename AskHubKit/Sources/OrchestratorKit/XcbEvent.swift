import Foundation

/// xcb（ループ共通の xcodebuild の入口）がイベントログ `events.jsonl` に 1 行ずつ書くイベント。
///
/// 共通のキーは `time`（ISO 8601）と `type`。未知の `type`・必要なキーが欠けた行・壊れた行は `init?(line:)` が `nil` を返す
/// （読み飛ばす）。`path` はローカルパスなので、GitHub に書く前にリポジトリとスロットに置き換える
public struct XcbEvent: Sendable, Equatable {
    public var time: Date
    public var kind: Kind

    public init(time: Date, kind: Kind) {
        self.time = time
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        /// ジョブが始まった
        case jobStarted(Started)
        /// ジョブを Mac（`host`。`local` は xcb を動かしている Mac）で試した。`attempt` は 1 から
        case jobAttempt(id: String, host: String, attempt: Int?)
        /// ジョブが `from` の Mac から別の Mac に移る（`reason` は `disconnected` / `no_platform` など）
        case jobMoved(id: String, from: String, reason: String?)
        /// ジョブが Mac の空きを待っている（`reason` は `no_test_host` など。任意）
        case jobWaiting(id: String, reason: String?)
        /// ジョブが終わった。`host` は最後に動いた Mac（どこでも動かなければ `nil`）
        case jobFinished(Finished)
        /// Mac の状態が変わった（`state` は `ok` / `down` など。`reason` は xcb の日本語の文で、ローカルパスを含むことがある）
        case hostState(host: String, state: String, reason: String?)
        /// Mac を候補から外した（`xcb drain`）
        case hostDrained(host: String)
        /// Mac を候補に戻した（`xcb undrain`）
        case hostUndrained(host: String)
    }

    /// `job_started` の中身
    public struct Started: Sendable, Equatable {
        public var id: String
        /// ビルドした作業ツリーのローカルパス
        public var path: String
        public var action: String
        public var platform: String?
        public var destination: String?

        public init(id: String, path: String, action: String, platform: String? = nil, destination: String? = nil) {
            self.id = id
            self.path = path
            self.action = action
            self.platform = platform
            self.destination = destination
        }
    }

    /// `job_finished` の中身
    public struct Finished: Sendable, Equatable {
        public var id: String
        public var path: String?
        public var action: String?
        public var platform: String?
        public var host: String?
        public var exitCode: Int?
        public var seconds: Int?
        public var attempts: Int?
        public var moves: Int?

        public init(
            id: String,
            path: String? = nil,
            action: String? = nil,
            platform: String? = nil,
            host: String? = nil,
            exitCode: Int? = nil,
            seconds: Int? = nil,
            attempts: Int? = nil,
            moves: Int? = nil
        ) {
            self.id = id
            self.path = path
            self.action = action
            self.platform = platform
            self.host = host
            self.exitCode = exitCode
            self.seconds = seconds
            self.attempts = attempts
            self.moves = moves
        }
    }

    /// 1 行を読む。読めない行は `nil`
    public init?(line: some StringProtocol) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let type = fields["type"] as? String,
              let timeText = fields["time"] as? String,
              let time = try? Date(timeText, strategy: .iso8601),
              let kind = Self.kind(type: type, fields: Fields(values: fields))
        else {
            return nil
        }
        self.init(time: time, kind: kind)
    }

    private static func kind(type: String, fields: Fields) -> Kind? {
        type.hasPrefix("host_") ? hostKind(type: type, fields: fields) : jobKind(type: type, fields: fields)
    }

    private static func jobKind(type: String, fields: Fields) -> Kind? {
        switch type {
        case "job_started":
            guard let id = fields.string("id"), let path = fields.string("path"), let action = fields.string("action") else {
                return nil
            }
            return .jobStarted(.init(
                id: id, path: path, action: action, platform: fields.string("platform"), destination: fields.string("destination")
            ))
        case "job_attempt":
            guard let id = fields.string("id"), let host = fields.string("host") else {
                return nil
            }
            return .jobAttempt(id: id, host: host, attempt: fields.int("attempt"))
        case "job_moved":
            guard let id = fields.string("id"), let from = fields.string("from") else {
                return nil
            }
            return .jobMoved(id: id, from: from, reason: fields.string("reason"))
        case "job_waiting":
            guard let id = fields.string("id") else {
                return nil
            }
            return .jobWaiting(id: id, reason: fields.string("reason"))
        case "job_finished":
            return finished(fields)
        default:
            return nil
        }
    }

    private static func hostKind(type: String, fields: Fields) -> Kind? {
        switch type {
        case "host_state":
            guard let host = fields.string("host"), let state = fields.string("state") else {
                return nil
            }
            return .hostState(host: host, state: state, reason: fields.string("reason"))
        case "host_drained":
            return fields.string("host").map { .hostDrained(host: $0) }
        case "host_undrained":
            return fields.string("host").map { .hostUndrained(host: $0) }
        default:
            return nil
        }
    }

    private static func finished(_ fields: Fields) -> Kind? {
        guard let id = fields.string("id") else {
            return nil
        }
        // どこでも動かなかったジョブは `host` が `none` になる
        let host = fields.string("host").flatMap { $0 == "none" ? nil : $0 }
        return .jobFinished(.init(
            id: id,
            path: fields.string("path"),
            action: fields.string("action"),
            platform: fields.string("platform"),
            host: host,
            exitCode: fields.int("rc"),
            seconds: fields.int("seconds"),
            attempts: fields.int("attempts"),
            moves: fields.int("moves")
        ))
    }

    /// 1 行の JSON のキー。空の文字列は無いものとして扱う（xcb は値が無いと `""` を書く）
    private struct Fields {
        var values: [String: Any]

        func string(_ key: String) -> String? {
            guard let value = values[key] as? String, !value.isEmpty else {
                return nil
            }
            return value
        }

        /// 数値で書かれていれば数値、文字列で書かれていれば数値として読めるときだけ（xcb の `${2:-null}` は `null` になる）
        func int(_ key: String) -> Int? {
            switch values[key] {
            case let number as NSNumber: number.intValue
            case let text as String: Int(text)
            default: nil
            }
        }
    }
}
