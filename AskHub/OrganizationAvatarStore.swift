import AskHubKit
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// organization のアバター画像のキャッシュ。ステータスタブの organization の節の見出しで使う。
/// 読み込んだ画像はアプリが動いている間持ち続け、スクロール・タブの切り替え・一覧の更新のたびに取り直さない
@MainActor
@Observable
final class OrganizationAvatarStore {
    enum Phase {
        case loading
        case loaded(CGImage)
        /// 失敗した時刻。`retryInterval` が過ぎるまでは取り直さない（失敗のたびに通信し続けないため）
        case failed(Date)
    }

    /// 見出しに出す大きさ（pt）。取得する画像の大きさ（px）もこれから決める
    nonisolated static let pointSize: CGFloat = 20
    /// Retina（最大 3 倍）でもぼやけない大きさで取る
    nonisolated static let pixelSize = Int(pointSize * 3)

    /// login の小文字ごとの読み込みの状態
    private(set) var phases: [String: Phase] = [:]

    /// 画像のデータを取る。失敗なら `nil`
    private let fetch: @Sendable (String) async -> Data?
    private let now: () -> Date
    private let retryInterval: TimeInterval

    init(
        fetch: @escaping @Sendable (String) async -> Data? = { login in
            try? await OrganizationAvatarFetcher().imageData(login: login, pixelSize: OrganizationAvatarStore.pixelSize)
        },
        now: @escaping () -> Date = Date.init,
        retryInterval: TimeInterval = 5 * 60
    ) {
        self.fetch = fetch
        self.now = now
        self.retryInterval = retryInterval
    }

    /// 通信しないストア。サンプルデータ（デモモード・Preview・UI テスト）で使い、常に代わりの表示を出す
    static func offline() -> OrganizationAvatarStore {
        OrganizationAvatarStore(fetch: { _ in nil })
    }

    func phase(for login: String) -> Phase? {
        phases[login.lowercased()]
    }

    /// まだ読み込んでいなければ読み込む。読み込み済み・読み込み中・失敗して間もないなら何もしない
    func load(_ login: String) async {
        let key = login.lowercased()
        switch phases[key] {
        case .loading, .loaded:
            return
        case let .failed(at) where now().timeIntervalSince(at) < retryInterval:
            return
        case .failed, nil:
            break
        }
        phases[key] = .loading
        let data = await fetch(login)
        // 見出しが画面の外に出て読み込みが取り消されたときは、失敗として残さず次に見えたときに取り直す
        if data == nil, Task.isCancelled {
            phases[key] = nil
            return
        }
        phases[key] = data.flatMap(Self.decode).map(Phase.loaded) ?? .failed(now())
    }

    /// 画像のデータを `CGImage` にする。読めない形式なら `nil`
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
