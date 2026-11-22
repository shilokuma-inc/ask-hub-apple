import AskHubBuild
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CryptoKit
import Foundation

/// 書き出しのワークフロー（app-kit の `app-store-creative.yml`）の artifact を取り込む（`docs/renewal/creative-assets.md` の「司令塔」）。
/// `creative-report`（`report.json`）と `creative-assets`（`<言語>/product-page-header.png`・`<言語>/search-results.png`）を落とし、
/// 寸法とアルファを確かめ、元の画像を常時オンの Mac に置き、見本（幅 600 の JPEG を base64 にした文字）を 1 回のコミットで書く
/// 取り込む 1 枚（リポジトリ・案の版・言語・種類）
struct CreativeImportTarget {
    var repo: RepositoryFullName
    var revision: Int
    var locale: String
    var kind: CreativeKind
}

/// app-kit の書き出しの `report.json`（読むところだけ）
struct CreativeReport: Decodable {
    struct Image: Decodable {
        var locale: String
        var kind: String
        var problems: [CreativeProblem]?
    }

    var problems: [CreativeProblem]?
    var images: [Image]?
    var failure: String?
}

struct CreativeImport: Sendable {
    /// artifact の名前（app-kit と同じ）
    static let assetsArtifact = "creative-assets"
    static let reportArtifact = "creative-report"
    /// `report.json` の大きさの上限
    static let reportLimit = 1024 * 1024

    /// 取り込んだ結果
    struct Imported: Equatable {
        var images: [CreativeFile.Image]
        /// 書き出しの問題（案ぜんたい）
        var problems: [CreativeProblem]
    }

    var store: any StateStore
    var hosting: any ReleaseHosting
    var extractor: any StoreScreenshotArtifactExtracting
    /// 元の画像を置くフォルダ（`<originals>/<言語>/<種類>.png`。案の版ごと）
    var originals: URL
    var log: @Sendable (String) -> Void

    /// 書き出しが失敗した実行の、`report.json` の失敗のわけ（読めなければ nil）
    func failure(of repo: RepositoryFullName, runID: Int) async -> String? {
        guard let artifacts = try? await hosting.runArtifacts(repo, runID: runID),
              let report = try? await readReport(repo, artifacts: artifacts) else { return nil }
        return report.failure
    }

    func execute(_ repo: RepositoryFullName, revision: Int, spec: CreativeSpec, runID: Int) async throws -> Imported {
        let artifacts = try await github { () throws(PullRequestError) in try await hosting.runArtifacts(repo, runID: runID) }
        let report = try await readReport(repo, artifacts: artifacts)
        if let failure = report.failure {
            throw ReleaseStepProblem("書き出せなかった（\(String(failure.prefix(500)))）", needsHuman: true)
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("askhub-creative-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folders = try await download(Self.assetsArtifact, from: artifacts, repo: repo) { zip throws in
            try await extractor.extract(zip, into: workspace)
        }
        // 言語のフォルダは、案の言語と同じでなければならない（足りない・余る言語のある artifact は取り込まない）
        let expected = Set(spec.locales.map(\.locale))
        let found = Set(folders.keys)
        guard found == expected else {
            let missing = expected.subtracting(found).sorted().joined(separator: "・")
            let extra = found.subtracting(expected).sorted().joined(separator: "・")
            let detail = [missing.isEmpty ? nil : "無い: \(missing)", extra.isEmpty ? nil : "余分: \(extra)"].compactMap(\.self)
            throw ReleaseStepProblem(
                "artifact \(Self.assetsArtifact) の言語が案と合わない（\(detail.joined(separator: "、"))）", needsHuman: true
            )
        }
        var images: [CreativeFile.Image] = []
        var previews: [String: String] = [:]
        for localization in spec.locales {
            for kind in CreativeKind.allCases {
                let target = CreativeImportTarget(repo: repo, revision: revision, locale: localization.locale, kind: kind)
                let (image, preview) = try take(folders, target: target, report: report)
                images.append(image)
                previews[image.preview] = preview
            }
        }
        do {
            try await store.writeTextFiles(previews, message: "\(repo) のクリエイティブアセットの案 \(revision) の見本（\(previews.count) 枚）")
        } catch {
            throw ReleaseStepProblem("クリエイティブアセットの見本を状態リポジトリに置けない（\(error)）", needsHuman: false)
        }
        // 案ぜんたいの問題は、司令塔が確かめたもの（案の cautions）と app-kit が確かめたものを、重ねずに持つ
        var problems = spec.cautions
        for problem in report.problems ?? [] where problem.isWellFormed && !problems.contains(problem) {
            problems.append(problem)
        }
        return Imported(images: images, problems: problems)
    }

    /// 1 枚を確かめて、元の画像を置き、見本（base64 の文字）を作る
    private func take(
        _ folders: [String: [URL]],
        target: CreativeImportTarget,
        report: CreativeReport
    ) throws -> (CreativeFile.Image, String) {
        let (repo, revision, locale, kind) = (target.repo, target.revision, target.locale, target.kind)
        let name = "\(locale)/\(kind.fileName)"
        guard let url = folders[locale]?.first(where: { $0.lastPathComponent == kind.fileName }) else {
            throw ReleaseStepProblem("artifact \(Self.assetsArtifact) に \(name) が無い", needsHuman: true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReleaseStepProblem("\(name) を読めない（\(error.localizedDescription)）", needsHuman: false)
        }
        if let problem = Self.imageProblem(data, kind: kind) { throw ReleaseStepProblem("\(name) \(problem)", needsHuman: true) }
        try keep(data, locale: locale, kind: kind)
        // 印と寸法は合うのに画像として読めない（壊れた PNG）。同じ artifact をやり直しても直らないので、案を作り直す
        guard let preview = ScreenshotDiff.preview(of: data) else {
            throw ReleaseStepProblem("\(name) を画像として読めず、見本を作れない。案を作り直す", needsHuman: true)
        }
        let problems = report.images?.first { $0.locale == locale && $0.kind == kind.rawValue }?.problems ?? []
        let image = CreativeFile.Image(
            locale: locale,
            kind: kind,
            md5: Self.md5(data),
            preview: StatePath.creativePreview(repo, revision: revision, locale: locale, kind: kind),
            problems: problems.filter(\.isWellFormed)
        )
        return (image, preview.base64EncodedString())
    }

    /// 元の画像のファイル（`<originals>/<言語>/<種類>.png`）
    static func original(in originals: URL, locale: String, kind: CreativeKind) -> URL {
        originals.appendingPathComponent(locale, isDirectory: true).appendingPathComponent("\(kind.rawValue).png")
    }

    /// 画像が書き出しの形（PNG・寸法・アルファなし）に合わないわけ。合えば nil
    static func imageProblem(_ data: Data, kind: CreativeKind) -> String? {
        let bytes = [UInt8](data.prefix(26))
        let isPNG = bytes.count == 26 && Data(bytes[0..<8]) == UnzipArtifactExtractor.pngSignature
        guard isPNG, Data(bytes[12..<16]) == Data("IHDR".utf8) else {
            return "が PNG でない"
        }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        guard (width, height) == kind.size else { return "の寸法が \(width)x\(height)（\(kind.size.width)x\(kind.size.height) のはず）" }
        // 色の種類 2 は RGB（アルファなし）。App Store Connect は透過を受け付けない
        guard bytes[25] == 2 else { return "にアルファがある（PNG の色の種類 \(bytes[25])）" }
        // RGB でも tRNS のチャンク（透過にする色）があれば透過になる。画像のデータ（IDAT）より前にしか置けない
        if hasTransparencyChunk(data) { return "に透過の指定（tRNS）がある" }
        return nil
    }

    /// IDAT より前に tRNS のチャンクがあるか（PNG の先頭の 8 バイトの後は、長さ 4・種類 4・中身・CRC 4 の並び）
    static func hasTransparencyChunk(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "tRNS" { return true }
            if type == "IDAT" || type == "IEND" { return false }
            offset += 12 + length
        }
        return false
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func keep(_ data: Data, locale: String, kind: CreativeKind) throws {
        let file = Self.original(in: originals, locale: locale, kind: kind)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            throw ReleaseStepProblem("書き出した画像を常時オンの Mac に置けない（\(error.localizedDescription)）", needsHuman: false)
        }
    }

    private func readReport(_ repo: RepositoryFullName, artifacts: [RunArtifact]) async throws -> CreativeReport {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("askhub-creative-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let data = try await download(Self.reportArtifact, from: artifacts, repo: repo) { zip throws in
            try await extractor.extractFile(zip, named: "report.json", maximumBytes: Self.reportLimit, into: workspace)
        }
        do {
            return try JSONDecoder().decode(CreativeReport.self, from: data)
        } catch {
            throw ReleaseStepProblem("書き出しの report.json の形が違う（\(error)）", needsHuman: true)
        }
    }

    /// artifact を落として取り出す。無い・期限切れ・大きすぎる・形が違うときは、人が直す（案を作り直す）問題
    private func download<Value>(
        _ name: String,
        from artifacts: [RunArtifact],
        repo: RepositoryFullName,
        extract: (Data) async throws -> Value
    ) async throws -> Value {
        guard let artifact = artifacts.first(where: { $0.name == name }) else {
            throw ReleaseStepProblem("書き出しの実行に artifact \(name) が無い（書き出しのジョブが失敗した）", needsHuman: true)
        }
        guard !artifact.expired else { throw ReleaseStepProblem("artifact \(name) の期限が切れた。案を作り直す", needsHuman: true) }
        guard artifact.size <= UnzipArtifactExtractor.maximumZipBytes else {
            throw ReleaseStepProblem("artifact \(name) が大きすぎる（\(artifact.size / 1_048_576) MB）", needsHuman: true)
        }
        let zip = try await github { () throws(PullRequestError) in try await hosting.downloadArtifact(repo, id: artifact.id) }
        do {
            return try await extract(zip)
        } catch let problem as ArtifactProblem {
            throw ReleaseStepProblem("artifact \(name) を取り込めない（\(problem.message)）", needsHuman: true)
        } catch let problem as ReleaseStepProblem {
            throw problem
        } catch {
            throw ReleaseStepProblem("artifact \(name) を取り出せない（\(error)）", needsHuman: false)
        }
    }

    private func github<Value>(_ body: () async throws(PullRequestError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            switch error {
            case .rateLimited, .serverError, .transport, .cancelled, .malformed, .headChanged:
                throw ReleaseStepProblem("GitHub に届かない（\(error)）", needsHuman: false)
            case .notFound:
                throw ReleaseStepProblem("書き出しの実行の artifact が無い（消された・期限が切れた）。案を作り直す", needsHuman: true)
            default:
                throw ReleaseStepProblem("GitHub に断られた（\(error)）", needsHuman: true)
            }
        }
    }
}
