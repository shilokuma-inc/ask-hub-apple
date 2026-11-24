@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 手で入れ替えたリポジトリの、呼んでいる版の記録（#1299）
struct AppKitDriftTests {
    static let now = Timestamp(AppKitRolloutTests.now)

    static func catalog(_ releases: [AppKitRelease]) -> AppKitCatalog {
        AppKitCatalog(releases: AppKitRolloutTests.releases(), source: FixedAppKitSource(releases: releases))
    }

    static func installation(
        _ installed: RepositoryFile.AppKit?,
        _ observed: AppKitObserved,
        build: RepositoryFile.Build? = nil,
        releases: [AppKitRelease]
    ) async throws -> RepositoryFile.AppKit? {
        try await AppKitWatch.installation(installed: installed, observed: observed, build: build, catalog: catalog(releases), now: now)
    }

    /// 手で入れ替えた（`appKit` の記録が無い）リポジトリは、ずれがあっても呼んでいる版を書き、ずれも書く
    @Test func recordsVersionOfRepositoryAdoptedByHand() async throws {
        let releases = [AppKitRolloutTests.release(AppKitRolloutTests.old), AppKitRolloutTests.release(AppKitRolloutTests.new)]
        let new = AppKitRolloutTests.new
        let build = try AppKitAdoptionTests.build()
        let observed = AppKitRolloutTests.observed(AppKitRolloutTests.release(new))
        let same = try await Self.installation(nil, observed, build: build, releases: releases)
        #expect(same == RepositoryFile.AppKit(ref: new.ref, version: new.version))
        var drifted = AppKitRolloutTests.observed(AppKitRolloutTests.release(new))
        drifted.files[".swiftlint.yml"] = String(repeating: "0", count: 40)
        let drift = try await Self.installation(nil, drifted, build: build, releases: releases)
        #expect(drift == RepositoryFile.AppKit(
            ref: new.ref,
            version: new.version,
            drift: ProtectionDrift(foundAt: Self.now, problems: [".swiftlint.yml が app-kit v1.0.1 の中身と違う"])
        ))
        // 次に点検したときは、同じずれのまま書き直さない
        #expect(try await Self.installation(drift, drifted, build: build, releases: releases) == drift)
    }

    /// 見つけた版に無いコミットを呼んでいれば、版を書かずにずれに書く。app-kit を呼んでいなければ何も書かない
    @Test func recordsUnknownCommitAndIgnoresRepositoryNotCallingAppKit() async throws {
        let releases = [AppKitRolloutTests.release(AppKitRolloutTests.old)]
        var observed = AppKitRolloutTests.observed(AppKitRolloutTests.release(AppKitRolloutTests.old))
        let unknown = String(repeating: "9", count: 40)
        observed.callerRef = unknown
        #expect(try await Self.installation(nil, observed, releases: releases) == RepositoryFile.AppKit(
            ref: unknown,
            drift: ProtectionDrift(foundAt: Self.now, problems: ["呼んでいる app-kit のコミット 9999999 が、見つけた版に無い"])
        ))
        observed.callerRef = nil
        #expect(try await Self.installation(nil, observed, releases: releases) == nil)
    }
}
