import AskHubJobs
import AskHubProtocol
import Foundation

/// epic の最終 PR の段取りのジョブの並び（`docs/renewal/flows.md` の「最終 PR までの段取り」）。司令塔の流れと人の意図の処理で同じ読み方をする。
///
/// 段取りのジョブは、前のジョブを `dependsOn` に持つ 1 本の列にする（検証だけは前を持たない）。
/// 人の意図で作る直し・マージも、そのときの最後のレビューにつなぐので、列は枝分かれしない
struct FinalChain {
    /// 最終 PR の段取りのジョブの種類
    static let kinds: Set<JobKind> = [
        .verifyBeforeFinal, .classifyDecisions, .captureScreenshots, .openFinalPullRequest, .reviewFinalPullRequest,
        .fixFinalPullRequest, .mergeFinalPullRequest, .cleanUp
    ]

    /// 作った順の並び（取り消したジョブを除く）。枝分かれ・途切れがあれば nil
    let ordered: [JobFile]?

    init(jobs: [JobFile]) {
        let chain = jobs.filter { Self.kinds.contains($0.kind) && $0.state != .canceled }
        let ids = Set(chain.map(\.id))
        var children: [ULID: [JobFile]] = [:]
        var roots: [JobFile] = []
        for job in chain {
            let parents = job.dependsOn.filter(ids.contains)
            if parents.isEmpty { roots.append(job) }
            for parent in parents { children[parent, default: []].append(job) }
        }
        var ordered: [JobFile] = []
        var current = roots.count == 1 ? roots.first : nil
        while let job = current, !ordered.contains(where: { $0.id == job.id }) {
            ordered.append(job)
            let next = children[job.id] ?? []
            current = next.count == 1 ? next.first : nil
        }
        self.ordered = ordered.count == chain.count ? ordered : nil
    }

    /// 最後のジョブ（次の一手を決めるもの）
    var leaf: JobFile? { ordered?.last }

    /// 最後の最終 PR のレビュー
    var latestReview: JobFile? { ordered?.last { $0.kind == .reviewFinalPullRequest } }

    /// 最後のレビューが見た最終 PR と head（人の意図の `targetVersion` と比べる今の head）
    var reviewed: PullRequestInput? { latestReview?.input(as: PullRequestInput.self) }

    /// 自動の直し（CI の失敗・必須の指摘）の回数。人が頼んだ直しは数えない
    var automaticFixes: Int {
        ordered?.filter { $0.kind == .fixFinalPullRequest && $0.input(as: FixTaskInput.self)?.reason != .human }.count ?? 0
    }

    /// 人が頼んだ直し（判断のカードへの「別案にする」「直してほしい」・最終 PR への指示）があるか
    var hasHumanFix: Bool {
        ordered?.contains { $0.kind == .fixFinalPullRequest && $0.input(as: FixTaskInput.self)?.reason == .human } ?? false
    }

    /// `job` の 1 つ前のジョブ
    func parent(of job: JobFile) -> JobFile? {
        guard let ordered, let index = ordered.firstIndex(where: { $0.id == job.id }), index > 0 else { return nil }
        return ordered[index - 1]
    }

    /// 最後のレビューの後に、ほかのジョブ（直し・仕分け・マージなど）がまだ無いか。人の意図で直し・マージを始めてよいのは、このときだけ
    var endsWithReview: Bool {
        guard let leaf, let latestReview else { return false }
        return leaf.id == latestReview.id
    }
}

/// 最終 PR の段取りのジョブの作り方（割り当てる Mac と使うもの）。司令塔の流れと人の意図の処理で同じものを使う
struct FinalJobs {
    var context: CommanderContext
    var epic: EpicFile
    /// epic の Mac。開始のときに人が選んだ Mac
    var epicMac: MacName
    var timing = JobTiming()

    init?(context: CommanderContext, epic: EpicFile) {
        guard let mac = epic.mac else { return nil }
        self.context = context
        self.epic = epic
        epicMac = mac
    }

    /// 使うもの。検証は全部のテストを流し、仕分けとレビューは Claude が読むだけ、作成・マージ・片付けはどちらも使わない
    static func needs(_ kind: JobKind) -> JobFile.Needs {
        switch kind {
        case .verifyBeforeFinal, .captureScreenshots: .init(claude: false, build: true)
        case .classifyDecisions, .reviewFinalPullRequest: .init(claude: true, build: false)
        case .fixFinalPullRequest: .init(claude: true, build: true)
        default: .init(claude: false, build: false)
        }
    }

    /// 動かす Mac。検証・撮影・片付けは epic の Mac、直しは epic の Mac がオンラインならそこで、オフラインなら常時オンの Mac、
    /// ほかは常時オンの Mac（ユーザーの決定）
    func mac(for kind: JobKind) async throws(CommanderError) -> MacName {
        switch kind {
        case .verifyBeforeFinal, .captureScreenshots, .cleanUp:
            return epicMac
        case .fixFinalPullRequest:
            // 作業場所と DerivedData が温まっている epic の Mac を先に使う
            return try await isOnline(epicMac) ? epicMac : context.mac
        default:
            return context.mac
        }
    }

    /// 生きている印が、オフラインとみなす時間より新しいか（印が無い・読めない Mac はオフラインとみなす）
    private func isOnline(_ name: MacName) async throws(CommanderError) -> Bool {
        guard let mac = try await context.readable(MacFile.self, at: StatePath.mac(name)), mac.mac == name else { return false }
        return context.now().timeIntervalSince(mac.seenAt.date) <= TimeInterval(timing.macStaleAfter.components.seconds)
    }

    /// `parent` の後に作るジョブ。id は元になった人の意図と `seed` から決める（やり直しても同じジョブを 2 つ作らない）
    func job(
        _ kind: JobKind,
        input: (any JobInput)?,
        after parent: JobFile?,
        origin: IntentReference,
        seed: String
    ) async throws(CommanderError) -> JobFile {
        let spec = JobSpec(
            kind: kind,
            mac: try await mac(for: kind),
            needs: Self.needs(kind),
            input: input?.jobInput ?? [:],
            dependsOn: parent.map { [$0.id] } ?? []
        )
        return context.job(spec, for: epic, origin: origin, seed: seed)
    }
}
