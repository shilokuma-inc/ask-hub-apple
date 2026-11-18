import Foundation

// 片付けの候補（`docs/renewal/operations.md` の「容量」）。ワーカーが作っていないもの（人が作った clone・Simulator・Xcode の DerivedData）を、
// 人がクライアントで「探す」を押したときだけ、その Mac のワーカーが探し、人が選んで「消す」を押したときだけ消す。
//
// クライアントは意図（`findCleanupCandidates`・`removeCleanupCandidates`）を書き、司令塔が受け付けて `cleanup/<mac>/requests.json` に積む。
// その Mac のワーカーは、積まれた頼みの元の意図の署名を自分で確かめてから探し・消し、結果を `cleanup/<mac>/candidates.json` に書く。
// 消すのは、ワーカーが自分で探して書いた候補の id だけ（意図に書かれたパスは使わない）

/// 片付けの候補を探す人の意図（`kind` が `findCleanupCandidates`）。封筒の repo・target・targetVersion は書かない。payload は `{mac}`
public struct FindCleanupCandidatesIntent: Equatable, Sendable {
    public static let kind = "findCleanupCandidates"

    /// 探す Mac
    public var mac: MacName
    public var intent: IntentReference

    public init(mac: MacName, intent: IntentReference) {
        self.mac = mac
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        try CleanupSubject.check(envelope, kind: Self.kind)
        let reader = try PayloadReader(envelope.payload, allowed: ["mac"])
        self.init(mac: try CleanupSubject.mac(reader), intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["mac": .string(mac.rawValue)] }
}

/// 選んだ候補を消す人の意図（`kind` が `removeCleanupCandidates`）。封筒の repo・target・targetVersion は書かない。
/// payload は `{mac, scannedAt, candidates}`。`scannedAt` は選んだ候補を探した時刻（その後に探し直していれば、ワーカーは消さない）
public struct RemoveCleanupCandidatesIntent: Equatable, Sendable {
    public static let kind = "removeCleanupCandidates"
    /// 1 回で消す候補の数の上限
    public static let maximumCandidates = 200

    public var mac: MacName
    public var scannedAt: Timestamp
    /// 消す候補の id（`CleanupCandidatesFile.Candidate.id`）。1 つ以上で、重ならない
    public var candidates: [String]
    public var intent: IntentReference

    public init(mac: MacName, scannedAt: Timestamp, candidates: [String], intent: IntentReference) {
        self.mac = mac
        self.scannedAt = scannedAt
        self.candidates = candidates
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        try CleanupSubject.check(envelope, kind: Self.kind)
        let reader = try PayloadReader(envelope.payload, allowed: ["mac", "scannedAt", "candidates"])
        let mac = try CleanupSubject.mac(reader)
        guard let scannedAt = Timestamp(rawValue: try reader.text("scannedAt", required: true, limit: 20)) else {
            throw .init(detail: "scannedAt の形が違う")
        }
        guard case let .array(values)? = reader.payload["candidates"] else { throw .init(detail: "candidates が無い") }
        let candidates = values.compactMap { value -> String? in
            guard case let .string(id) = value, CleanupCandidatesFile.Candidate.isID(id) else { return nil }
            return id
        }
        guard !candidates.isEmpty, candidates.count == values.count, candidates.count <= Self.maximumCandidates,
              Set(candidates).count == candidates.count else {
            throw .init(detail: "candidates は 1 つ以上・\(Self.maximumCandidates) 個まで・重ならない候補の id")
        }
        let intent = IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        self.init(mac: mac, scannedAt: scannedAt, candidates: candidates, intent: intent)
    }

    public var payload: [String: JSONValue] {
        ["mac": .string(mac.rawValue), "scannedAt": .string(scannedAt.rawValue), "candidates": .array(candidates.map(JSONValue.string))]
    }
}

/// 片付けの意図の封筒の決まり（repo・target・targetVersion を持たない）と、payload の `mac` の読み方
enum CleanupSubject {
    static func check(_ envelope: IntentEnvelope, kind: String) throws(MalformedIntent) {
        guard envelope.kind == kind else { throw .init(detail: "kind が \(kind) でない") }
        guard envelope.repo == nil, envelope.target == nil, envelope.targetVersion == nil else {
            throw .init(detail: "\(kind) に repo・target・targetVersion がある")
        }
    }

    static func mac(_ reader: PayloadReader) throws(MalformedIntent) -> MacName {
        guard let mac = MacName(rawValue: try reader.text("mac", required: true, limit: 32)) else { throw .init(detail: "mac の形が違う") }
        return mac
    }
}

/// `cleanup/<mac>/requests.json`（片付けの頼み）。司令塔だけが書く。受け付けた片付けの意図を、新しいものを後ろにして積む
public struct CleanupRequestsFile: StateFile {
    public static let formatVersion = 1
    /// 残す頼みの数（古いものから落とす。ワーカーは済ませた頼みを `candidates.json` に記録するので、落としても困らない）
    public static let keptRequests = 20

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// 探す（`findCleanupCandidates`）
        case find
        /// 選んだ候補を消す（`removeCleanupCandidates`）
        case remove
    }

    public struct Request: Codable, Equatable, Sendable {
        /// 元の人の意図。ワーカーは、この意図の署名を確かめてから動く
        public var intent: IntentReference
        public var action: Action
        /// 消す候補の id と、それを探した時刻（`remove` のときだけ）
        public var candidates: [String]?
        public var scannedAt: Timestamp?
        public var acceptedAt: Timestamp

        public init(
            intent: IntentReference,
            action: Action,
            candidates: [String]? = nil,
            scannedAt: Timestamp? = nil,
            acceptedAt: Timestamp
        ) {
            self.intent = intent
            self.action = action
            self.candidates = candidates
            self.scannedAt = scannedAt
            self.acceptedAt = acceptedAt
        }
    }

    public var requests: [Request]

    public init(requests: [Request] = []) {
        self.requests = requests
    }

    public var violations: [String] {
        var violations: [String] = []
        if requests.count > Self.keptRequests { violations.append("requests は \(Self.keptRequests) 件まで") }
        for request in requests {
            switch request.action {
            case .find where request.candidates != nil || request.scannedAt != nil:
                violations.append("find に candidates・scannedAt がある")
            case .remove where (request.candidates ?? []).isEmpty || request.scannedAt == nil:
                violations.append("remove に candidates・scannedAt が無い")
            default:
                break
            }
            if !(request.candidates ?? []).allSatisfy(CleanupCandidatesFile.Candidate.isID) { violations.append("candidates の id の形が違う") }
        }
        return violations
    }
}

/// `cleanup/<mac>/candidates.json`（片付けの候補と、頼みを済ませた記録）。その Mac のワーカーだけが書く
public struct CleanupCandidatesFile: StateFile {
    public static let formatVersion = 1
    /// 残す「済ませた記録」の数
    public static let keptHandled = 20
    /// 書く候補の数の上限（大きいものから）
    public static let maximumCandidates = 200

    public struct Candidate: Codable, Equatable, Sendable {
        /// 候補の id。種類と場所から決まる 16 桁の 16 進（探し直しても同じものは同じ id）
        public var id: String
        public var kind: CleanupCandidateKind
        /// 人が読む名前（clone のフォルダの名前・Simulator の名前とランタイムなど）
        public var name: String
        /// 場所。clone と DerivedData はホームからのパス（`~/Desktop/ios/old-app`）、Simulator は UDID
        public var location: String
        /// 大きさ（バイト）
        public var bytes: Int64
        /// 最後に使った時刻（clone は最後に触った時刻、Simulator は `lastUsedAt`、DerivedData は更新の時刻）。分からなければ nil
        public var lastUsedAt: Timestamp?
        /// 消す前に確かめたこと（未コミット・未 push・stash・起動中など）。問題が無ければ nil。問題があるものは消さない
        public var caution: String?

        public init(
            id: String,
            kind: CleanupCandidateKind,
            name: String,
            location: String,
            bytes: Int64,
            lastUsedAt: Timestamp? = nil,
            caution: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.location = location
            self.bytes = bytes
            self.lastUsedAt = lastUsedAt
            self.caution = caution
        }

        /// 候補の id の形（16 桁の 16 進の小文字）か
        public static func isID(_ text: String) -> Bool {
            text.utf8.count == 16 && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
        }
    }

    /// 頼みを済ませた記録
    public struct Handled: Codable, Equatable, Sendable {
        public var intent: IntentReference
        public var action: CleanupRequestsFile.Action
        public var at: Timestamp
        /// 消した（ゴミ箱に移した）候補の id
        public var removed: [String]?
        /// 消さなかった候補と理由
        public var skipped: [CleanupSkip]?
        /// 頼み全体を済ませられなかった理由（署名を確かめられない・探せないなど）。済ませたなら nil
        public var problem: String?

        public init(
            intent: IntentReference,
            action: CleanupRequestsFile.Action,
            at: Timestamp,
            removed: [String]? = nil,
            skipped: [CleanupSkip]? = nil,
            problem: String? = nil
        ) {
            self.intent = intent
            self.action = action
            self.at = at
            self.removed = removed
            self.skipped = skipped
            self.problem = problem
        }
    }

    public var mac: MacName
    /// 最後に探し終えた時刻。まだ探していなければ nil
    public var scannedAt: Timestamp?
    public var candidates: [Candidate]
    /// 探せなかった場所（読む許可が無いなど）。ホームからのパス
    public var unreadable: [String]?
    public var handled: [Handled]

    public init(
        mac: MacName,
        scannedAt: Timestamp? = nil,
        candidates: [Candidate] = [],
        unreadable: [String]? = nil,
        handled: [Handled] = []
    ) {
        self.mac = mac
        self.scannedAt = scannedAt
        self.candidates = candidates
        self.unreadable = unreadable
        self.handled = handled
    }

    /// その意図の頼みを済ませたか
    public func hasHandled(_ intent: IntentReference) -> Bool {
        handled.contains { $0.intent == intent }
    }

    public var violations: [String] {
        var violations: [String] = []
        if candidates.count > Self.maximumCandidates { violations.append("candidates は \(Self.maximumCandidates) 件まで") }
        if !candidates.allSatisfy({ Candidate.isID($0.id) }) { violations.append("candidates の id の形が違う") }
        if Set(candidates.map(\.id)).count != candidates.count { violations.append("candidates の id が重なっている") }
        if candidates.contains(where: { $0.bytes < 0 || $0.name.isEmpty || $0.location.isEmpty }) {
            violations.append("candidates の bytes は 0 以上、name と location は空でない")
        }
        if handled.count > Self.keptHandled { violations.append("handled は \(Self.keptHandled) 件まで") }
        return violations
    }
}

/// 片付けの候補の種類（`CleanupCandidatesFile.Candidate.kind`）
public enum CleanupCandidateKind: String, Codable, Sendable, CaseIterable {
    /// 人が作った git の clone（ゴミ箱に移す）
    case clone
    /// 人が作った Simulator（ゴミ箱に移せないので消す。元に戻せない）
    case simulator
    /// Xcode の DerivedData の 1 つのプロジェクトのフォルダ（ゴミ箱に移す）
    case derivedData
}

/// 消さなかった候補と理由（`CleanupCandidatesFile.Handled.skipped`）
public struct CleanupSkip: Codable, Equatable, Sendable {
    public var id: String
    public var reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}
